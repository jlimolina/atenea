#!/bin/bash

#-----------------------------------------------------------------------
# Instalador Automático para la Aplicación "Atenea" v2.0
# Prepara un servidor, instala Ollama, y despliega la aplicación
# con Gunicorn y Nginx.
#
# USO:
# 1. Sube tu proyecto a un servidor (ej. con 'git clone').
# 2. Navega a la carpeta del proyecto.
# 3. Dale permisos de ejecución: chmod +x setup.sh
# 4. Ejecútalo: ./setup.sh
#-----------------------------------------------------------------------

# Salir inmediatamente si un comando falla
set -e

echo "--- 🚀 Iniciando el instalador de Atenea AI (con Ollama) 🚀 ---"
echo "Este script configurará el servidor para producción."

# --- PASO 1: Recopilar información del usuario ---
read -p "Introduce el dominio para tu aplicación (ej. atenea.midominio.com). Pulsa ENTER para usar 'localhost': " DOMAIN_NAME
# Si el usuario no introduce nada, se usará 'localhost' por defecto
DOMAIN_NAME=${DOMAIN_NAME:-localhost}

# Detectar el usuario actual y la ruta del proyecto
CURRENT_USER=$(whoami)
PROJECT_DIR=$(pwd)
echo "--------------------------------------------------"
echo "Configuración a utilizar:"
echo "Dominio: $DOMAIN_NAME"
echo "Usuario del servicio: $CURRENT_USER"
echo "Directorio del proyecto: $PROJECT_DIR"
echo "--------------------------------------------------"
read -p "¿Es correcta esta configuración? (s/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Ss]$ ]]
then
    echo "Instalación abortada."
    exit 1
fi

# --- PASO 2: Instalar dependencias del sistema ---
echo -e "\n--- 📦 Instalando dependencias del sistema (Nginx, Python, Git, Curl) ---"
sudo apt-get update
sudo apt-get install -y python3.11 python3.11-venv nginx git curl

# --- PASO 3: Instalar y configurar Ollama ---
echo -e "\n--- 🦙 Instalando y configurando Ollama ---"
# Comprobamos si el comando 'ollama' ya existe
if command -v ollama &> /dev/null
then
    echo "Ollama ya está instalado. Saltando la instalación."
else
    echo "Ollama no encontrado. Descargando e instalando con el script oficial..."
    curl -fsSL https://ollama.com/install.sh | sh
fi
# El script de instalación de Ollama ya crea y habilita el servicio systemd,
# pero nos aseguramos de que esté activo.
echo "Asegurando que el servicio de Ollama esté en ejecución y habilitado..."
sudo systemctl daemon-reload
sudo systemctl enable ollama
sudo systemctl start ollama

# --- PASO 4: Configurar el entorno de Python ---
echo -e "\n--- 🐍 Configurando el entorno virtual de Python ---"
echo "Creando entorno virtual en 'venv'..."
python3.11 -m venv venv

echo "Activando entorno e instalando dependencias de Python..."
# Usamos la ruta absoluta al pip del venv para evitar problemas
"$PROJECT_DIR/venv/bin/pip" install -r requirements.txt

echo "Entorno de Python listo."

# --- PASO 5: Configurar el servicio de systemd para Atenea ---
echo -e "\n--- ⚙️ Configurando Gunicorn con systemd para la app Atenea ---"

# Creamos el archivo de servicio.
# Añadimos 'Requires' y 'After' para que espere a Ollama.
cat <<EOF | sudo tee /etc/systemd/system/atenea.service
[Unit]
Description=Gunicorn instance para servir la aplicación Atenea
Requires=ollama.service
After=network.target ollama.service

[Service]
User=$CURRENT_USER
Group=www-data
WorkingDirectory=$PROJECT_DIR
Environment="PATH=$PROJECT_DIR/venv/bin"
ExecStart=$PROJECT_DIR/venv/bin/gunicorn --workers 3 --bind unix:atenea.sock -m 007 app:app
Restart=always

[Install]
WantedBy=multi-user.target
EOF

echo "Iniciando y habilitando el servicio 'atenea'..."
sudo systemctl daemon-reload
sudo systemctl restart atenea # Usamos restart para aplicar cambios si ya existía
sudo systemctl enable atenea

echo "Servicio de Atenea configurado y en ejecución."

# --- PASO 6: Configurar Nginx como Reverse Proxy ---
echo -e "\n--- 🌐 Configurando Nginx como servidor web (Reverse Proxy) ---"

cat <<EOF | sudo tee /etc/nginx/sites-available/atenea
server {
    listen 80;
    server_name $DOMAIN_NAME;

    location / {
        include proxy_params;
        proxy_pass http://unix:$PROJECT_DIR/atenea.sock;
    }

    location /static {
        alias $PROJECT_DIR/static;
    }
}
EOF

echo "Habilitando la configuración del sitio en Nginx..."
# Creamos un enlace simbólico para activar la configuración
sudo ln -s -f /etc/nginx/sites-available/atenea /etc/nginx/sites-enabled/

# Eliminamos la configuración por defecto de Nginx si existe
if [ -f /etc/nginx/sites-enabled/default ]; then
    sudo rm /etc/nginx/sites-enabled/default
fi

echo "Probando configuración de Nginx y reiniciando el servicio..."
sudo nginx -t
sudo systemctl restart nginx

# --- Finalización ---
echo -e "\n--- ✅ ¡Instalación completada! ---"
echo "Tu aplicación Atenea ahora debería estar accesible en: http://$DOMAIN_NAME"
echo "Puedes comprobar el estado de los servicios con:"
echo "sudo systemctl status atenea"
echo "sudo systemctl status ollama"
