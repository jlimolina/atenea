#!/bin/bash

#-----------------------------------------------------------------------
# Instalador Final para "Atenea" v6.0
#
# DESPLIEGUE DIRECTO CON PYTHON: Configura la aplicación para
# ejecutarse desde su propio directorio usando el servidor de Flask
# y un servicio de systemd.
# Incluye todas las correcciones de dependencias y entorno.
#-----------------------------------------------------------------------

# Salir inmediatamente si un comando falla.
set -e

echo "--- 🚀 Iniciando el instalador Final de Atenea AI 🚀 ---"

# --- PASO 1: Confirmar la configuración ---
PROJECT_DIR=$(pwd)
CURRENT_USER=$(whoami)

echo "--------------------------------------------------"
echo "La aplicación se instalará en el directorio actual:"
echo "Directorio del proyecto: $PROJECT_DIR"
echo "Usuario del servicio:    $CURRENT_USER"
echo "La app será accesible en: http://<IP_DEL_SERVIDOR>:5000"
echo "--------------------------------------------------"
read -p "¿Continuar con esta configuración? (s/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Ss]$ ]]; then
    echo "Instalación cancelada por el usuario."
    exit 1
fi

# --- PASO 2: Instalar dependencias del sistema ---
echo -e "\n--- 📦 Instalando dependencias del sistema y repositorio de Python ---"
sudo apt-get update
sudo apt-get install -y software-properties-common curl
if ! grep -q "deadsnakes" /etc/apt/sources.list.d/*; then
    sudo add-apt-repository -y ppa:deadsnakes/ppa
fi
sudo apt-get update
sudo apt-get install -y python3.11 python3.11-venv git

# --- PASO 3: Instalar y configurar Ollama ---
echo -e "\n--- 🦙 Instalando y configurando Ollama ---"
if command -v ollama &> /dev/null; then
    echo "Ollama ya está instalado. Verificando que el servicio esté activo..."
else
    echo "Ollama no encontrado. Descargando e instalando..."
    curl -fsSL https://ollama.com/install.sh | sh
fi
echo "Asegurando que el servicio de Ollama esté en ejecución y habilitado para el arranque..."
sudo systemctl daemon-reload
sudo systemctl enable ollama
sudo systemctl start ollama

# --- PASO 4: Configurar el entorno de Python ---
echo -e "\n--- 🐍 Configurando el entorno virtual y las dependencias ---"
cd "$PROJECT_DIR"

if [ -d "venv" ]; then
    echo "El directorio 'venv' ya existe. Omitiendo creación."
else
    echo "Creando entorno virtual en 'venv'..."
    python3.11 -m venv venv
fi

echo "Instalando dependencias de Python desde requirements.txt (esto puede tardar)..."
"$PROJECT_DIR/venv/bin/pip" install -r requirements.txt
echo "Entorno de Python y dependencias configurados."

# --- PASO 5: Configurar el servicio de systemd para Atenea ---
echo -e "\n--- ⚙️ Configurando el servicio de systemd para la app Atenea ---"
cat <<EOF | sudo tee /etc/systemd/system/atenea.service
[Unit]
Description=Aplicación de IA Atenea
Requires=ollama.service
After=network.target ollama.service

[Service]
User=$CURRENT_USER
Group=$(id -gn $CURRENT_USER)
WorkingDirectory=$PROJECT_DIR

# Entornos CRÍTICOS para que todo funcione
# PATH: Para que el servicio encuentre los ejecutables de python/pip.
# HOME: Para que TTS encuentre los modelos descargados y la licencia aceptada.
Environment="PATH=$PROJECT_DIR/venv/bin:/usr/bin"
Environment="HOME=/home/$CURRENT_USER"

# --- CONFIGURACIÓN DE EJECUCIÓN ---
# Opción A (Tu elección): Usar el servidor de desarrollo de Flask. Simple pero no recomendado para producción.
ExecStart=$PROJECT_DIR/venv/bin/python3 $PROJECT_DIR/app.py

# Opción B (Recomendado para el futuro): Usar un servidor de producción como Gunicorn. Es más estable y robusto.
# Para usarlo, comenta la línea de arriba y descomenta la de abajo.
# ExecStart=$PROJECT_DIR/venv/bin/gunicorn --workers 1 --bind 0.0.0.0:5000 --timeout 120 app:app

Restart=always

[Install]
WantedBy=multi-user.target
EOF

echo "Iniciando y habilitando el servicio 'atenea'..."
sudo systemctl daemon-reload
sudo systemctl restart atenea
sudo systemctl enable atenea

echo "Servicio de Atenea configurado y en ejecución."

# --- Finalización ---
echo -e "\n--- ✅ ¡Instalación completada! ---"
echo "Tu aplicación Atenea ahora debería estar accesible en la red."
echo "Para acceder, usa la IP de tu servidor seguida del puerto 5000."
echo "Ejemplo: http://192.168.1.100:5000"
echo ""
echo "Recuerda que para que Coqui TTS funcione, debes aceptar la licencia la primera vez"
echo "ejecutando el modelo de forma interactiva, como hicimos en la depuración."
echo ""
echo "Para ver los logs de la aplicación en tiempo real, usa:"
echo "  journalctl -u atenea -f"
