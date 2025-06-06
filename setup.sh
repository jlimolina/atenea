#!/bin/bash

#-----------------------------------------------------------------------
# Instalador Automático de Producción para "Atenea" v3.0
#
# Este script prepara un servidor Linux (basado en Debian/Ubuntu),
# instala todas las dependencias de sistema y de Python,
# configura Ollama, y despliega la aplicación Flask con Gunicorn y Nginx.
# Es idempotente y seguro de ejecutar.
#-----------------------------------------------------------------------

# Salir inmediatamente si un comando falla para evitar instalaciones parciales.
set -e

echo "--- 🚀 Iniciando el instalador de Producción de Atenea AI 🚀 ---"

# --- PASO 1: Recopilar y confirmar la configuración ---
# Solicita el nombre de dominio al usuario. Si no se introduce nada, se usa 'localhost'.
read -p "Introduce el dominio para tu aplicación (ej. atenea.midominio.com). Pulsa ENTER para usar 'localhost': " DOMAIN_NAME
DOMAIN_NAME=${DOMAIN_NAME:-localhost}

# Detecta automáticamente el usuario actual y la ruta absoluta del proyecto.
CURRENT_USER=$(whoami)
PROJECT_DIR=$(pwd)

echo "--------------------------------------------------"
echo "Se usará la siguiente configuración para el despliegue:"
echo "Dominio:               $DOMAIN_NAME"
echo "Usuario del servicio:    $CURRENT_USER"
echo "Directorio del proyecto: $PROJECT_DIR"
echo "--------------------------------------------------"
read -p "¿Es correcta esta configuración? (s/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Ss]$ ]]; then
    echo "Instalación cancelada por el usuario."
    exit 1
fi

# --- PASO 2: Instalar dependencias del sistema y PPA de Python ---
echo -e "\n--- 📦 Instalando dependencias del sistema y repositorio de Python ---"
sudo apt-get update
# Instala las herramientas básicas para gestionar repositorios.
sudo apt-get install -y software-properties-common curl
# Añade el PPA "deadsnakes" que contiene las últimas versiones de Python.
sudo add-apt-repository -y ppa:deadsnakes/ppa
# Actualiza la lista de paquetes para incluir los del nuevo PPA.
sudo apt-get update
# Instala la versión específica de Python, Nginx y Git.
sudo apt-get install -y python3.11 python3.11-venv nginx git

# --- PASO 3: Instalar y configurar Ollama ---
echo -e "\n--- 🦙 Instalando y configurando Ollama ---"
if command -v ollama &> /dev/null; then
    echo "Ollama ya está instalado. Verificando que el servicio esté activo..."
else
    echo "Ollama no encontrado. Descargando e instalando con el script oficial..."
    # Descarga y ejecuta el script oficial de instalación de Ollama.
    curl -fsSL https://ollama.com/install.sh | sh
fi
# El script de Ollama configura el servicio systemd, pero nos aseguramos de que esté
# habilitado (para que inicie con el sistema) y en ejecución.
echo "Asegurando que el servicio de Ollama esté en ejecución y habilitado..."
sudo systemctl daemon-reload
sudo systemctl enable ollama
sudo systemctl start ollama

# --- PASO 4: Configurar el entorno de Python ---
echo -e "\n--- 🐍 Configurando el entorno virtual de Python ---"
if [ -d "venv" ]; then
    echo "La carpeta 'venv' ya existe. Omitiendo la creación."
else
    echo "Creando entorno virtual en 'venv'..."
    python3.11 -m venv venv
fi

echo "Instalando dependencias de Python desde requirements.txt..."
# Usa la ruta absoluta al pip del venv para garantizar que se instala en el lugar correcto.
"$PROJECT_DIR/venv/bin/pip" install -r requirements.txt

echo "Entorno de Python configurado."

# --- PASO 5: Configurar el servicio de systemd para Atenea ---
echo -e "\n--- ⚙️ Configurando Gunicorn con systemd para la app Atenea ---"
# Se usa 'cat' con un Here Document (EOF) para crear el archivo de servicio dinámicamente.
# Esto nos permite insertar variables como $CURRENT_USER y $PROJECT_DIR.
cat <<EOF | sudo tee /etc/systemd/system/atenea.service
[Unit]
Description=Gunicorn instance para servir la aplicación Atenea
# Dependencias: No iniciar este servicio hasta que la red y Ollama estén activos.
Requires=ollama.service
After=network.target ollama.service

[Service]
# Ejecuta el servicio como el usuario actual, no como root.
User=$CURRENT_USER
# Permite que Nginx (grupo www-data) acceda al socket.
Group=www-data
# El directorio de trabajo de la aplicación.
WorkingDirectory=$PROJECT_DIR
# Asegura que el PATH del sistema incluya el binario del entorno virtual.
Environment="PATH=$PROJECT_DIR/venv/bin"
# El comando que se ejecutará para iniciar la aplicación.
ExecStart=$PROJECT_DIR/venv/bin/gunicorn --workers 3 --bind unix:atenea.sock -m 007 app:app
# Reinicia el servicio automáticamente si falla.
Restart=always

[Install]
# Habilita el servicio para que se inicie en el arranque del sistema.
WantedBy=multi-user.target
EOF

echo "Iniciando y habilitando el servicio 'atenea'..."
sudo systemctl daemon-reload
# Usamos restart para asegurar que se aplican los cambios si el servicio ya existía.
sudo systemctl restart atenea
sudo systemctl enable atenea

echo "Servicio de Atenea configurado y en ejecución."

# --- PASO 6: Configurar Nginx como Reverse Proxy ---
echo -e "\n--- 🌐 Configurando Nginx como servidor web (Reverse Proxy) ---"
cat <<EOF | sudo tee /etc/nginx/sites-available/atenea
server {
    listen 80;
    server_name $DOMAIN_NAME;

    # Sirve los archivos estáticos (CSS, JS) directamente para mayor eficiencia.
    location /static {
        alias $PROJECT_DIR/static;
    }

    # Pasa todas las demás peticiones a la aplicación Gunicorn a través del socket.
    location / {
        include proxy_params;
        proxy_pass http://unix:$PROJECT_DIR/atenea.sock;
    }
}
EOF

echo "Habilitando la configuración del sitio en Nginx..."
# Crea un enlace simbólico en 'sites-enabled' para activar la configuración.
sudo ln -s -f /etc/nginx/sites-available/atenea /etc/nginx/sites-enabled/

# Es una buena práctica eliminar la configuración por defecto de Nginx.
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

