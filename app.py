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
from TTS.api import TTS
from torch.serialization import safe_globals
from TTS.tts.configs.xtts_config import XttsConfig

# Configuración de logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s', handlers=[logging.StreamHandler()])

app = Flask(__name__)

# Configuración
OLLAMA_HOST = 'http://localhost:11434'
LLM_TIMEOUT = 180

# Filtro Jinja
def nl2br(value):
    return value.replace('\n', '<br>') if value else ''
app.jinja_env.filters['nl2br'] = nl2br

# --- ARQUITECTURA MULTI-MOTOR TTS ---

# 1. Caché para los modelos cargados
silero_vits_model = None
coqui_xtts_model = None

def get_silero_model():
    """Carga el modelo Silero VITS bajo demanda."""
    global silero_vits_model
    if silero_vits_model:
        return silero_vits_model
    
    logging.info("Cargando modelo Silero VITS...")
    # Configuración especial para evitar problemas de descarga
    torch.hub.set_dir(os.path.expanduser('~/.cache/torch/hub'))
    torch.hub._validate_not_a_forked_repo = lambda a, b, c: True
    model, _ = torch.hub.load(
        repo_or_dir='snakers4/silero-models', model='silero_tts',
        language='es', speaker='v3_es', trust_repo=True
    )
    silero_vits_model = model
    logging.info("Modelo Silero VITS cargado.")
    return silero_vits_model

def get_coqui_model():
    """Carga el modelo Coqui TTS (XTTS v2) bajo demanda."""
    global coqui_xtts_model
    if coqui_xtts_model:
        return coqui_xtts_model
    
    device = 'cuda' if torch.cuda.is_available() else 'cpu'
    logging.info(f"Cargando modelo Coqui TTS en dispositivo: {device}. ¡Puede tardar la primera vez!")
    with safe_globals([XttsConfig]):
        model = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to(device)
    coqui_xtts_model = model
    logging.info("Modelo Coqui TTS cargado.")
    return coqui_xtts_model

def generate_silero_audio(text, speaker):
    """Genera audio con Silero y devuelve el tensor y su sample rate."""
    model = get_silero_model()
    audio_tensor = model.apply_tts(text=text, speaker=speaker, sample_rate=48000)
    return audio_tensor.unsqueeze(0), 48000

def generate_coqui_audio(text, speaker_wav):
    """Genera audio con Coqui y devuelve el tensor y su sample rate."""
    model = get_coqui_model()
    wav_output = model.tts(text=text, speaker_wav=speaker_wav, language="es")
    audio_tensor = torch.tensor(wav_output).unsqueeze(0)
    return audio_tensor, 24000

# 2. Registro de Motores
TTS_ENGINES = {
    'silero': generate_silero_audio,
    'coqui': generate_coqui_audio,
}

# --- FIN DE LA ARQUITECTURA MULTI-MOTOR ---

# ... (Las funciones check_ollama_connection y get_ollama_models no cambian) ...
def check_ollama_connection():
    try:
        response = requests.get(f"{OLLAMA_HOST}/api/tags", timeout=5)
        return response.status_code == 200
    except (requests.exceptions.RequestException, ConnectionError):
        return False

def get_ollama_models():
    try:
        response = requests.get(f"{OLLAMA_HOST}/api/tags", timeout=5)
        response.raise_for_status()
        return [model['name'] for model in response.json().get('models', [])]
    except Exception as e:
        logging.error(f"Error al obtener modelos de Ollama: {str(e)}")
        return []

@app.route('/')
def index():
    # ... (Esta ruta no cambia) ...
    ollama_available = check_ollama_connection()
    model_names = get_ollama_models() if ollama_available else []
    error_message = None
    if not ollama_available:
        error_message = "Ollama no está disponible."
    elif not model_names:
        error_message = "Ollama está corriendo pero no hay modelos."
    return render_template('index.html', models=model_names, error=error_message)

@app.route('/ask', methods=['POST'])
def ask():
    data = request.form
    question = data.get('question', '').strip()
    mode = data.get('mode', 'llm')

    if not question:
        return jsonify({"error": "Texto requerido"}), 400

    if mode == 'llm':
        # --- Lógica LLM (sin cambios) ---
        selected_model = data.get('model')
        if not selected_model:
            return jsonify({"error": "Modelo no seleccionado"}), 400
        try:
            response = ollama.chat(model=selected_model, messages=[{'role': 'user', 'content': question}], options={'timeout': LLM_TIMEOUT})
            return render_template('response.html', response=response['message']['content'], question=question, model=selected_model, mode=mode)
        except Exception as e:
            # ... (manejo de errores de LLM sin cambios) ...
            error_msg = {socket.gaierror: "Error de red"}.get(type(e), f"Error: {str(e)}")
            logging.error(f"Error LLM: {error_msg}")
            return render_template('response.html', response=error_msg, question=question, model=selected_model, mode=mode)

    elif mode == 'tts':
        # --- Lógica TTS (Refactorizada) ---
        try:
            selected_engine_name = request.form.get('tts_engine', 'silero')
            selected_speaker = request.form.get('tts_speaker')

            generation_function = TTS_ENGINES.get(selected_engine_name)
            if not generation_function:
                raise ValueError(f"Motor TTS no válido: {selected_engine_name}")

            logging.info(f"Generando audio con motor '{selected_engine_name}' y voz '{selected_speaker}'...")
            
            # Llama a la función correspondiente, que devuelve el audio y su sample rate
            audio_tensor, sample_rate = generation_function(question, selected_speaker)
            
            # Proceso común de conversión a base64
            audio_data = io.BytesIO()
            torchaudio.save(audio_data, audio_tensor, sample_rate, format='wav')
            audio_data.seek(0)
            
            if audio_data.getbuffer().nbytes < 100:
                raise RuntimeError("El archivo de audio generado es demasiado pequeño")

            audio_base64 = base64.b64encode(audio_data.read()).decode('utf-8')
            logging.info("Audio generado exitosamente.")

            return render_template(
                'response.html',
                response=audio_base64,
                question=question,
                model=f"Motor: {selected_engine_name}, Voz: {os.path.basename(selected_speaker)}",
                mode=mode
            )
        except Exception as e:
            logging.error(f"Error en TTS: {str(e)}", exc_info=True)
            return render_template('response.html', response=f"Error al generar audio: {e}", question=question, model="Error TTS", mode=mode)

# ... (la ruta /system_status y el bloque if __name__ == '__main__' no necesitan grandes cambios) ...
@app.route('/system_status')
def system_status():
    status = {"ollama_available": check_ollama_connection(), "ollama_models": get_ollama_models()}
    return jsonify(status)

if __name__ == '__main__':
    print("\n" + "="*50 + "\nAtenea - Servicio Multimodal de IA\n" + "="*50)
    # Ya no precargamos ningún modelo, se cargarán bajo demanda.
    app.run(host='0.0.0.0', port=5000, debug=True)
