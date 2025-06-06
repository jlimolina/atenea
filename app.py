from flask import Flask, request, render_template, send_file, jsonify
import ollama
import logging
import socket
import io
import time
import torch
import torchaudio
import base64
import psutil
import os
import requests
from functools import wraps

# Configuración mejorada de logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler()
    ]
)

app = Flask(__name__)

# Configuración
OLLAMA_HOST = 'http://localhost:11434'
MAX_TTS_LENGTH = 5000
LLM_TIMEOUT = 180

# Filtro personalizado para convertir saltos de línea en <br>
def nl2br(value):
    """Convierte saltos de línea en etiquetas HTML <br>"""
    return value.replace('\n', '<br>') if value else ''

app.jinja_env.filters['nl2br'] = nl2br

# Inicialización de modelos
tts_model = None
vits_model = None
logging.info("Sistema de TTS inicializado (carga bajo demanda)")

def check_ollama_connection():
    """Verifica si Ollama está disponible"""
    try:
        response = requests.get(f"{OLLAMA_HOST}/api/tags", timeout=5)
        return response.status_code == 200
    except (requests.exceptions.RequestException, ConnectionError):
        return False

def get_ollama_models():
    """Obtiene modelos de Ollama con manejo robusto de errores"""
    try:
        response = requests.get(f"{OLLAMA_HOST}/api/tags", timeout=5)
        response.raise_for_status()
        data = response.json()
        return [model['name'] for model in data.get('models', [])]
    except Exception as e:
        logging.error(f"Error al obtener modelos de Ollama: {str(e)}")
        return []

def get_vits_model():
    """Obtiene el modelo VITS con manejo mejorado de errores"""
    global vits_model

    if vits_model is not None:
        return vits_model

    try:
        # Verificar memoria disponible
        mem = psutil.virtual_memory()
        if mem.available < 2 * 1024 * 1024 * 1024:  # 2GB mínimo recomendado
            logging.warning(f"Memoria baja disponible: {mem.available/(1024*1024):.2f}MB")

        logging.info("Descargando modelo VITS...")
        start_time = time.time()

        # Configuración especial para evitar problemas de descarga
        torch.hub.set_dir(os.path.expanduser('~/.cache/torch/hub'))
        torch.hub._validate_not_a_forked_repo = lambda a, b, c: True

        # Cargar modelo con configuración actualizada
        vits_model, _ = torch.hub.load(
            repo_or_dir='snakers4/silero-models',
            model='silero_tts',
            language='es',
            speaker='v3_es', 
            trust_repo=True,
            verbose=True
        )

        # Mover a CPU/GPU según disponibilidad
        device = 'cuda' if torch.cuda.is_available() else 'cpu'
        vits_model.to(device)
        logging.info(f"Modelo VITS cargado en {time.time() - start_time:.2f} segundos (dispositivo: {device})")

        # Prueba de generación de audio
        with torch.no_grad():
            test_text = "Prueba de audio exitosa"
            test_audio = vits_model.apply_tts(text=test_text, speaker='es_0')
            
            if not isinstance(test_audio, torch.Tensor):
                raise RuntimeError("El modelo no generó tensor de audio válido")
            
            if test_audio.dim() != 1 or test_audio.numel() == 0:
                raise RuntimeError("Audio generado no válido")

            # Generar archivo de prueba
            test_path = "test_audio.wav"
            torchaudio.save(test_path, test_audio.unsqueeze(0), 48000)
            logging.info(f"Archivo de prueba generado en: {test_path}")

        return vits_model

    except Exception as e:
        logging.error(f"Error crítico al cargar VITS: {str(e)}", exc_info=True)
        vits_model = None
        return None

@app.route('/')
def index():
    """Ruta principal mejorada con verificación de dependencias"""
    tts_available = False
    error_message = None

    # Verificar Ollama
    ollama_available = check_ollama_connection()
    model_names = get_ollama_models() if ollama_available else []
    
    if not ollama_available:
        error_message = "Ollama no está disponible. Por favor inicia el servicio."
    elif not model_names:
        error_message = "Ollama está corriendo pero no hay modelos disponibles."

    # Verificar TTS
    try:
        import torchaudio
        tts_available = True
    except ImportError:
        error_message = (error_message + " | " if error_message else "") + "Torchaudio no instalado"
        tts_available = False

    return render_template(
        'index.html',
        models=model_names,
        error=error_message,
        tts_available=tts_available
    )

@app.route('/ask', methods=['POST'])
def ask():
    """Versión mejorada con mejor manejo de errores"""
    data = request.form
    question = data.get('question', '').strip()
    selected_model = data.get('model')
    mode = data.get('mode', 'llm')

    # Validaciones comunes
    if not question:
        return jsonify({"error": "Texto requerido"}), 400
    if len(question) > MAX_TTS_LENGTH and mode == 'tts':
        return jsonify({"error": f"Texto demasiado largo para TTS (máx {MAX_TTS_LENGTH} chars)"}), 400

    # Modo TTS
    if mode == 'tts':
        try:
            model = get_vits_model()
            if model is None:
                raise RuntimeError("Modelo de voz no disponible. Verifica los logs para más información.")

            logging.info(f"Generando audio para texto: {question[:50]}...")

            # Generación de audio
            with torch.no_grad():
                audio = model.apply_tts(text=question[:MAX_TTS_LENGTH], speaker='es_0')
                if audio.numel() == 0:
                    raise RuntimeError("El modelo generó audio vacío")

            # Convertir a bytes
            audio_data = io.BytesIO()
            torchaudio.save(audio_data, audio.unsqueeze(0), 48000, format='wav')
            audio_data.seek(0)

            # Verificar contenido del audio
            if audio_data.getbuffer().nbytes < 100:
                raise RuntimeError("El archivo de audio generado es demasiado pequeño")

            audio_base64 = base64.b64encode(audio_data.read()).decode('utf-8')
            logging.info("Audio generado exitosamente")
            
            return render_template(
                'response.html',
                response=audio_base64,
                question=question,
                model="VITS (Silero)",
                mode=mode
            )

        except Exception as e:
            logging.error(f"Error en TTS: {str(e)}", exc_info=True)
            return render_template(
                'response.html',
                response=f"Error al generar audio: {str(e)}. Verifica la terminal para más detalles.",
                question=question,
                model="VITS (Silero)",
                mode=mode
            )

    # Modo LLM
    elif mode == 'llm':
        if not selected_model:
            return jsonify({"error": "Modelo no seleccionado"}), 400

        try:
            response = ollama.chat(
                model=selected_model,
                messages=[{'role': 'user', 'content': question}],
                options={'timeout': LLM_TIMEOUT}
            )
            return render_template(
                'response.html',
                response=response['message']['content'],
                question=question,
                model=selected_model,
                mode=mode
            )
        except Exception as e:
            error_msg = {
                socket.gaierror: "Error de red",
                ConnectionRefusedError: "Ollama no responde",
                TimeoutError: "Tiempo agotado"
            }.get(type(e), f"Error: {str(e)}")

            logging.error(f"Error LLM: {error_msg}")
            return render_template(
                'response.html',
                response=error_msg,
                question=question,
                model=selected_model,
                mode=mode
            )

@app.route('/generate_tts', methods=['POST'])
def generate_tts():
    """Endpoint API mejorado para TTS"""
    try:
        data = request.get_json()
        if not data or 'text' not in data:
            return jsonify({"error": "Datos inválidos"}), 400

        text = data['text'].strip()[:MAX_TTS_LENGTH]
        if not text:
            return jsonify({"error": "Texto vacío"}), 400

        model = get_vits_model()
        if not model:
            return jsonify({"error": "Modelo no disponible"}), 503

        # Generación eficiente
        with torch.no_grad():
            audio = model.apply_tts(text=text, speaker='es_0')
            if audio.numel() == 0:
                raise RuntimeError("El modelo generó audio vacío")

        audio_data = io.BytesIO()
        torchaudio.save(audio_data, audio.unsqueeze(0), 48000, 'wav')
        audio_data.seek(0)

        return send_file(
            audio_data,
            mimetype="audio/wav",
            as_attachment=False,
            download_name="atenea_audio.wav"
        )

    except Exception as e:
        logging.error(f"Error API TTS: {str(e)}")
        return jsonify({"error": str(e)}), 500

@app.route('/system_status')
def system_status():
    """Endpoint para diagnóstico"""
    status = {
        "memory": {
            "total": psutil.virtual_memory().total / (1024**3),
            "available": psutil.virtual_memory().available / (1024**3)
        },
        "ollama_available": check_ollama_connection(),
        "ollama_models": get_ollama_models(),
        "tts_loaded": vits_model is not None,
        "torch_version": torch.__version__,
        "torchaudio_version": torchaudio.__version__ if 'torchaudio' in globals() else "No disponible",
        "audio_test_file": os.path.exists("test_audio.wav")
    }
    return jsonify(status)

if __name__ == '__main__':
    print("\n" + "="*50)
    print("Atenea - Servicio Multimodal de IA")
    print("="*50)
    print(f"PyTorch: {torch.__version__}")
    print(f"Torchaudio: {torchaudio.__version__}")
    print(f"Memoria disponible: {psutil.virtual_memory().available/(1024**3):.2f} GB")
    print(f"Ollama disponible: {'Sí' if check_ollama_connection() else 'No'}")

    # Precargar modelo en segundo plano
    device = 'cuda' if torch.cuda.is_available() else 'cpu'
    print(f"Usando dispositivo: {device}")

    # Verificar TTS
    print("\nProbando sistema TTS...")
    try:
        get_vits_model()
        print("✅ Sistema TTS listo")
    except Exception as e:
        print(f"❌ Error en TTS: {str(e)}")

    app.run(host='0.0.0.0', port=5000, debug=True)
