#!/bin/bash

#-----------------------------------------------------------------------
# Instalador Automático para la Aplicación "Atenea"
# Este script prepara un servidor Linux (basado en Debian/Ubuntu)
# para desplegar la aplicación Flask con Gunicorn y Nginx.
#
# USO:
# 1. Sube tu proyecto a un servidor (ej. con 'git clone').
# 2. Navega a la carpeta del proyecto.
# 3. Dale permisos de ejecución: chmod +x setup.sh
# 4. Ejecútalo: ./setup.sh
#-----------------------------------------------------------------------

# Salir inmediatamente si un comando falla
set -e

echo "--- 🚀 Iniciando el instalador de Atenea AI 🚀 ---"
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
echo -e "\n--- 📦 Instalando dependencias del sistema (Nginx, Python, Git) ---"
sudo apt-get update
sudo apt-get install -y python3.11 python3.11-venv nginx git

# --- PASO 3: Configurar el entorno de Python ---
echo -e "\n--- 🐍 Configurando el entorno virtual de Python ---"
echo "Creando entorno virtual en 'venv'..."
python3.11 -m venv venv

echo "Activando entorno e instalando dependencias de Python..."
source venv/bin/activate
pip install -r requirements.txt
deactivate # Desactivamos para que los siguientes pasos usen rutas absolutas

echo "Entorno de Python listo."

# --- PASO 4: Configurar el servicio de systemd ---
echo -e "\n--- ⚙️ Configurando Gunicorn con systemd para ejecutar la app en segundo plano ---"

# Usamos 'cat' con un Here Document (EOF) para crear el archivo de servicio dinámicamente
# Usamos 'tee' para escribir el archivo con permisos de sudo
cat <<EOF | sudo tee /etc/systemd/system/atenea.service
[Unit]
Description=Gunicorn instance para servir la aplicación Atenea
After=network.target

[Service]
User=$CURRENT_USER
Group=www-data
WorkingDirectory=$PROJECT_DIR
Environment="PATH=$PROJECT_DIR/venv/bin"
ExecStart=$PROJECT_DIR/venv/bin/gunicorn --workers 3 --bind unix:atenea.sock -m 007 app:app

[Install]
WantedBy=multi-user.target
EOF

echo "Iniciando y habilitando el servicio 'atenea'..."
sudo systemctl daemon-reload
sudo systemctl start atenea
sudo systemctl enable atenea

echo "Servicio systemd configurado y en ejecución."

# --- PASO 5: Configurar Nginx como Reverse Proxy ---
echo -e "\n--- 🌐 Configurando Nginx como servidor web (Reverse Proxy) ---"

# Creamos el archivo de configuración de Nginx
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
echo "Puedes comprobar el estado del servicio con: sudo systemctl status atenea"
