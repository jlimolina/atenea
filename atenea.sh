#!/bin/bash

# --- Lanzador para la aplicación Atenea y Ollama ---

# Configuración
OLLAMA_HOST="http://localhost:11434"
FLASK_APP_FILE="app.py"
VENV_PATH="venv/bin/activate"

# Variable para saber si este script inició Ollama
OLLAMA_STARTED_BY_SCRIPT=false

# Función de limpieza que se ejecutará al salir (ej. con Ctrl+C)
cleanup() {
    echo -e "\n🛑 Deteniendo los servicios..."
    # Si este script fue el que inició Ollama, lo detenemos
    if [ "$OLLAMA_STARTED_BY_SCRIPT" = true ] && [ -n "$OLLAMA_PID" ]; then
        echo "   -> Deteniendo el proceso de Ollama (PID: $OLLAMA_PID)..."
        kill $OLLAMA_PID
    else
        echo "   -> No se detiene Ollama porque ya estaba en ejecución."
    fi
    echo "✅ Limpieza completada."
    exit 0
}

# 'trap' captura la señal de interrupción (Ctrl+C) y llama a la función cleanup
trap cleanup INT TERM

# 1. Comprobar si Ollama ya está en ejecución
echo "🔍 Comprobando el estado de Ollama..."
if pgrep -x "ollama" > /dev/null; then
    echo "   -> Ollama ya está en ejecución."
else
    echo "   -> Ollama no está en ejecución. Iniciando..."
    # Inicia 'ollama serve' en segundo plano
    ollama serve &
    # Guarda el Process ID (PID) del proceso de Ollama
    OLLAMA_PID=$!
    OLLAMA_STARTED_BY_SCRIPT=true
    echo "   -> Ollama iniciado en segundo plano (PID: $OLLAMA_PID)."
fi

# 2. Esperar a que el servidor de Ollama esté listo
echo "⏳ Esperando a que el servidor de Ollama esté disponible en $OLLAMA_HOST..."
# Bucle que intenta conectar con Ollama cada segundo, con un timeout de 60s
for i in {1..60}; do
    # Usamos curl para comprobar si el endpoint responde
    if curl -s --head $OLLAMA_HOST > /dev/null; then
        echo "   -> 🎉 ¡Ollama está listo!"
        break
    fi
    echo -n "."
    sleep 1
done

# Si después del bucle sigue sin responder, salimos con un error
if ! curl -s --head $OLLAMA_HOST > /dev/null; then
    echo -e "\n❌ Error: Ollama no respondió después de 60 segundos."
    cleanup
    exit 1
fi

# 3. Activar el entorno virtual de Python
echo "🐍 Activando el entorno virtual de Python..."
if [ -f "$VENV_PATH" ]; then
    source $VENV_PATH
    echo "   -> Entorno virtual activado."
else
    echo "❌ Error: No se encontró el entorno virtual en '$VENV_PATH'."
    exit 1
fi

# 4. Lanzar la aplicación Flask
echo "🚀 Lanzando la aplicación Atenea (Flask)..."
echo "    (Presiona Ctrl+C para detener todo)"
python $FLASK_APP_FILE

# Si el script llega aquí (por ejemplo, si Flask falla), llamamos a cleanup
cleanup
