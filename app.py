from flask import Flask, request, render_template, send_file, jsonify, redirect, url_for, Response
from werkzeug.utils import secure_filename
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
import json
import subprocess
import re
from functools import wraps
from TTS.api import TTS
from torch.serialization import safe_globals
from TTS.tts.configs.xtts_config import XttsConfig
from TTS.tts.models.xtts import XttsAudioConfig, XttsArgs
from TTS.config.shared_configs import BaseDatasetConfig
from diffusers import StableDiffusionPipeline


logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s', handlers=[logging.StreamHandler()])

app = Flask(__name__)

UPLOAD_FOLDER = 'voices'
app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER
os.makedirs(app.config['UPLOAD_FOLDER'], exist_ok=True)

OLLAMA_HOST = 'http://localhost:11434'
LLM_TIMEOUT = 180

def nl2br(value):
    return value.replace('\n', '<br>') if value else ''
app.jinja_env.filters['nl2br'] = nl2br

# --- Caché de Modelos ---
silero_vits_model = None
coqui_xtts_model = None
sd_pipeline = None

# --- Arquitectura Multi-Motor TTS ---

def get_silero_model():
    global silero_vits_model
    if silero_vits_model: return silero_vits_model
    logging.info("Cargando modelo Silero VITS...")
    torch.hub.set_dir(os.path.expanduser('~/.cache/torch/hub'))
    torch.hub._validate_not_a_forked_repo = lambda a, b, c: True
    model, _ = torch.hub.load(repo_or_dir='snakers4/silero-models', model='silero_tts', language='es', speaker='v3_es', trust_repo=True)
    silero_vits_model = model
    logging.info("Modelo Silero VITS cargado.")
    return silero_vits_model

def get_coqui_model():
    global coqui_xtts_model
    if coqui_xtts_model: return coqui_xtts_model
    device = 'cuda' if torch.cuda.is_available() else 'cpu'
    logging.info(f"Cargando modelo Coqui TTS en dispositivo: {device}. ¡Puede tardar la primera vez!")
    with safe_globals([XttsConfig, XttsAudioConfig, BaseDatasetConfig, XttsArgs]):
        model = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to(device)
    coqui_xtts_model = model
    logging.info("Modelo Coqui TTS cargado.")
    return coqui_xtts_model

def get_sd_model(model_id="runwayml/stable-diffusion-v1-5"):
    global sd_pipeline
    if sd_pipeline: return sd_pipeline
    device = 'cuda' if torch.cuda.is_available() else 'cpu'
    logging.info(f"Cargando pipeline de Stable Diffusion '{model_id}' en dispositivo: {device}. ¡Esto tardará mucho!")
    pipe = StableDiffusionPipeline.from_pretrained(model_id, torch_dtype=torch.float16 if device == 'cuda' else torch.float32)
    pipe = pipe.to(device)
    sd_pipeline = pipe
    logging.info("Pipeline de Stable Diffusion cargado.")
    return sd_pipeline

def generate_silero_audio(text, speaker):
    model = get_silero_model()
    audio_tensor = model.apply_tts(text=text, speaker=speaker, sample_rate=48000)
    return audio_tensor.unsqueeze(0), 48000

def generate_coqui_audio(text, speaker_wav):
    model = get_coqui_model()
    wav_output = model.tts(text=text, speaker_wav=speaker_wav, language="es")
    audio_tensor = torch.tensor(wav_output).unsqueeze(0)
    return audio_tensor, 24000

def generate_sd_image(prompt, model_id):
    pipe = get_sd_model(model_id)
    image = pipe(prompt).images[0]
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    img_str = base64.b64encode(buffer.getvalue()).decode("utf-8")
    return img_str

TTS_ENGINES = {'silero': generate_silero_audio, 'coqui': generate_coqui_audio}
IMAGE_ENGINES = {'stable-diffusion-1.5': generate_sd_image}

# --- Rutas de la Aplicación ---

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
    ollama_available = check_ollama_connection()
    installed_models = get_ollama_models() if ollama_available else []
    error_message = None
    if not ollama_available:
        error_message = "Ollama no está disponible."
    elif not installed_models:
        error_message = "Ollama está corriendo pero no hay modelos instalados."
    try:
        voice_files = [f for f in os.listdir(app.config['UPLOAD_FOLDER']) if f.endswith('.wav')]
    except FileNotFoundError:
        voice_files = []
    return render_template('index.html', models=installed_models, error=error_message, available_voices=voice_files)

@app.route('/manage')
def manage_page():
    ollama_available = check_ollama_connection()
    error_message = None
    if not ollama_available:
        error_message = "Ollama no está disponible para gestionar modelos."
    
    installed_models = get_ollama_models() if ollama_available else []

    try:
        with open('models_catalog.json', 'r', encoding='utf-8') as f:
            # Ahora simplemente leemos el JSON que ya está agrupado
            grouped_models = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        grouped_models = {}
        if not error_message:
            error_message = "Error: No se pudo cargar o parsear 'models_catalog.json'."
    
    return render_template(
        'manage.html',
        models=installed_models,
        grouped_models=grouped_models,
        error=error_message
    )

@app.route('/ask', methods=['POST'])
def ask():
    data = request.form
    question = data.get('question', '').strip()
    mode = data.get('mode', 'llm')

    if not question:
        return jsonify({"error": "Texto requerido"}), 400

    if mode == 'llm':
        selected_model = data.get('model')
        if not selected_model: return jsonify({"error": "Modelo no seleccionado"}), 400
        try:
            start_time = time.time()
            response = ollama.chat(model=selected_model, messages=[{'role': 'user', 'content': question}], options={'timeout': LLM_TIMEOUT})
            elapsed_time = round(time.time() - start_time, 2)
            return render_template('response.html', response=response['message']['content'], question=question, model=selected_model, mode=mode, elapsed_time=elapsed_time)
        except Exception as e:
            error_msg = {socket.gaierror: "Error de red", ConnectionRefusedError: "Ollama no responde"}.get(type(e), f"Error: {str(e)}")
            return render_template('response.html', response=error_msg, question=question, model=selected_model, mode=mode, elapsed_time=None)

    elif mode == 'tts':
        try:
            selected_engine_name = request.form.get('tts_engine', 'silero')
            selected_speaker = request.form.get('tts_speaker')
            generation_function = TTS_ENGINES.get(selected_engine_name)
            if not generation_function: raise ValueError(f"Motor TTS no válido: {selected_engine_name}")
            
            audio_tensor, sample_rate = generation_function(question, selected_speaker)
            audio_data = io.BytesIO()
            torchaudio.save(audio_data, audio_tensor, sample_rate, format='wav')
            audio_data.seek(0)
            audio_base64 = base64.b64encode(audio_data.getvalue()).decode('utf-8')
            return render_template('response.html', response=audio_base64, question=question, model=f"Motor: {selected_engine_name}, Voz: {os.path.basename(selected_speaker)}", mode=mode)
        except Exception as e:
            return render_template('response.html', response=f"Error al generar audio: {e}", question=question, model="Error TTS", mode=mode)

    elif mode == 'text-to-image':
        try:
            selected_engine_name = request.form.get('image_engine')
            generation_function = IMAGE_ENGINES.get(selected_engine_name)
            if not generation_function: raise ValueError(f"Motor de imagen no válido: {selected_engine_name}")

            start_time = time.time()
            image_base64 = generation_function(question, "runwayml/stable-diffusion-v1-5")
            elapsed_time = round(time.time() - start_time, 2)
            
            return render_template('response.html', response=image_base64, question=question, model=f"Motor: {selected_engine_name}", mode=mode, elapsed_time=elapsed_time)
        except Exception as e:
            return render_template('response.html', response=f"Error al generar imagen: {e}", question=question, model="Error T2I", mode=mode)

# ... (resto de rutas sin cambios) ...
@app.route('/upload_voice', methods=['POST'])
def upload_voice():
    if 'voice_file' not in request.files: return redirect(request.url)
    file = request.files['voice_file']
    if file.filename == '': return redirect(request.url)
    if file and file.filename.endswith('.wav'):
        filename = secure_filename(file.filename)
        file.save(os.path.join(app.config['UPLOAD_FOLDER'], filename))
        return redirect(url_for('index'))
    return 'Formato de archivo no válido. Sube un .wav', 400

@app.route('/download_model')
def download_model():
    model_name = request.args.get('model_name')
    if not model_name: return Response("Error: No se especificó el nombre del modelo.", status=400)
    def generate_stream():
        command = ["ollama", "pull", model_name]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding='utf-8', bufsize=1)
        progress_regex = re.compile(r'(\d+)\s*%')
        for line in iter(process.stdout.readline, ''):
            clean_line = line.strip()
            progress_match = progress_regex.search(clean_line)
            response_data = {"type": "progress", "percent": int(progress_match.group(1)), "status": clean_line} if progress_match else {"type": "log", "message": clean_line}
            yield f"data: {json.dumps(response_data)}\n\n"
        process.stdout.close()
        final_status = {"type": "done", "success": process.wait() == 0}
        yield f"data: {json.dumps(final_status)}\n\n"
        yield "event: close\ndata: close\n\n"
    return Response(generate_stream(), mimetype='text/event-stream')

if __name__ == '__main__':
    print("\n" + "="*50 + "\nAtenea - Servicio Multimodal de IA\n" + "="*50)
    app.run(host='0.0.0.0', port=5000, debug=True)

