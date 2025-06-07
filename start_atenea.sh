#!/bin/bash
# Script para iniciar Atenea AI Assistant

# Iniciar Ollama en segundo plano
echo "🦙 Iniciando Ollama en segundo plano..."
ollama serve > /dev/null 2>&1 &
OLLAMA_PID=$!

# Esperar que Ollama esté listo
sleep 3

# Activar entorno virtual
source .venv/bin/activate

# Iniciar aplicación
echo "🌐 Iniciando servidor web..."
echo "========================================"
echo "  ACCEDE A LA APLICACIÓN EN TU NAVEGADOR"
echo "  http://localhost:5000"
echo "========================================"
python app.py

# Detener Ollama al salir
echo "🛑 Deteniendo Ollama..."
kill $OLLAMA_PID
