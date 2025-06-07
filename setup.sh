#!/bin/bash

#-----------------------------------------------------------------------
# Instalador Automático de Producción para "Atenea" v5.0
#
# DESPLIEGUE PROFESIONAL: Mueve la aplicación a /var/www, instala
# dependencias, configura Ollama, y despliega con Gunicorn y Nginx,
# solucionando definitivamente los problemas de permisos.
#-----------------------------------------------------------------------

# Salir inmediatamente si un comando falla para evitar instalaciones parciales.
set -e

echo "--- 🚀 Iniciando el instalador de Producción de Atenea AI 🚀 ---"

# --- PASO 1: Recopilar y confirmar la configuración ---
read -p "Introduce el dominio para tu aplicación (ej. atenea.midominio.com). Pulsa ENTER para usar 'localhost': " DOMAIN_NAME
DOMAIN_NAME=${DOMAIN_NAME:-localhost}

CURRENT_USER=$(whoami)
# CORRECCIÓN DEFINITIVA: Se define el directorio estándar de despliegue web.
PROJECT_DIR="/var/www/atenea"

echo "--------------------------------------------------"
echo "Se usará la siguiente configuración para el despliegue:"
echo "Dominio:               $DOMAIN_NAME"
echo "Usuario del servicio:    $CURRENT_USER"
echo "Directorio del proyecto: $PROJECT_DIR (estándar de producción)"
echo "--------------------------------------------------"
read -p "¿Es correcta esta configuración? (s/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Ss]$ ]]; then
    echo "Instalación cancelada por el usuario."
    exit 1
fi

# --- PASO 2: Mover el proyecto a la ubicación estándar ---
echo -e "\n--- 🚚 Moviendo archivos del proyecto a $PROJECT_DIR ---"
# Copia el contenido del directorio actual a la nueva ubicación.
sudo mkdir -p $PROJECT_DIR
# Usamos rsync para una copia eficiente.
sudo rsync -a --delete "$(pwd)/" "$PROJECT_DIR/"
# Asigna la propiedad del nuevo directorio al usuario actual para que pueda gestionarlo.
sudo chown -R $CURRENT_USER:$CURRENT_USER $PROJECT_DIR

# --- PASO 3: Instalar dependencias del sistema y PPA de Python ---
echo -e "\n--- 📦 Instalando dependencias del sistema y repositorio de Python ---"
sudo apt-get update
sudo apt-get install -y software-properties-common curl
sudo add-apt-repository -y ppa:deadsnakes/ppa
sudo apt-get update
sudo apt-get install -y python3.11 python3.11-venv nginx git

# --- PASO 4: Instalar y configurar Ollama ---
echo -e "\n--- 🦙 Instalando y configurando Ollama ---"
if command -v ollama &> /dev/null; then
    echo "Ollama ya está instalado. Verificando que el servicio esté activo..."
else
    echo "Ollama no encontrado. Descargando e instalando con el script oficial..."
    curl -fsSL https://ollama.com/install.sh | sh
fi
echo "Asegurando que el servicio de Ollama esté en ejecución y habilitado para el arranque..."
sudo systemctl daemon-reload
sudo systemctl enable ollama
sudo systemctl start ollama

# --- PASO 5: Configurar el entorno de Python en la nueva ubicación ---
echo -e "\n--- 🐍 Configurando el entorno virtual de Python en $PROJECT_DIR ---"
cd $PROJECT_DIR # Nos movemos al nuevo directorio para los siguientes pasos.

if [ -d "venv" ]; then
    echo "La carpeta 'venv' ya existe. Omitiendo la creación del entorno."
else
    echo "Creando entorno virtual en 'venv'..."
    python3.11 -m venv venv
fi

echo "Instalando dependencias de Python desde requirements.txt..."
"$PROJECT_DIR/venv/bin/pip" install -r requirements.txt
echo "Entorno de Python configurado."

# --- PASO 6: Configurar el servicio de systemd para Atenea ---
echo -e "\n--- ⚙️ Configurando Gunicorn con systemd para la app Atenea ---"
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
ExecStart=$PROJECT_DIR/venv/bin/gunicorn --workers 3 --bind unix:/run/atenea.sock -m 007 --timeout 120 app:app
Restart=always

[Install]
WantedBy=multi-user.target
EOF

echo "Iniciando y habilitando el servicio 'atenea'..."
sudo systemctl daemon-reload
sudo systemctl restart atenea
sudo systemctl enable atenea

echo "Servicio de Atenea configurado y en ejecución."

# --- PASO 7: Configurar Nginx como Reverse Proxy ---
echo -e "\n--- 🌐 Configurando Nginx como servidor web ---"
cat <<EOF | sudo tee /etc/nginx/sites-available/atenea
server {
    listen 80;
    server_name $DOMAIN_NAME;

    location /static {
        alias $PROJECT_DIR/static;
    }

    location / {
        proxy_connect_timeout 600s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
        fastcgi_send_timeout 600s;
        fastcgi_read_timeout 600s;
        include proxy_params;
        proxy_pass http://unix:/run/atenea.sock;
    }
}
EOF

echo "Habilitando la configuración del sitio en Nginx..."
sudo ln -s -f /etc/nginx/sites-available/atenea /etc/nginx/sites-enabled/

if [ -f /etc/nginx/sites-enabled/default ]; then
    sudo rm /etc/nginx/sites-enabled/default
fi

echo "Probando la sintaxis de Nginx y reiniciando el servicio..."
sudo nginx -t
sudo systemctl restart nginx

# --- Finalización ---
echo -e "\n--- ✅ ¡Instalación completada! ---"
echo "Tu aplicación Atenea ahora debería estar accesible en: http://$DOMAIN_NAME"
echo "Puedes comprobar el estado de los servicios en cualquier momento con:"
echo "  sudo systemctl status atenea"
echo "  sudo systemctl status ollama"
echo "Para ver los logs de la aplicación en tiempo real, usa:"
echo "  journalctl -u atenea -f"


