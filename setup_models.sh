#!/bin/bash


# PASO 0: Healthcheck de CUDA — falla rápido si el pod tiene GPU rota
echo "================================================"
echo "  Checking CUDA Before Continuing..."
echo "================================================"
CUDA_OK=$(python3 -c "import torch; print(torch.cuda.is_available())" 2>/dev/null)

if [ "$CUDA_OK" != "True" ]; then
    echo ""
    echo "🔴 CRITICAL ERROR: CUDA is not available in this pod."
    echo "🔴 nvidia-smi may look fine, but torch.cuda.is_available() = False"
    echo "🔴 This is a host infrastructure issue (GPU passthrough break)."
    echo "🔴 ACTION: STOP this pod and launch a new one — DON'T keep going; you'll waste time and money"
    echo ""
    echo "--- POD DIAGNOSIS ---"
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv 2>&1 || echo "nvidia-smi also failed"
    python3 -c "import torch; print('torch:', torch.__version__, 'cuda build:', torch.version.cuda)" 2>&1
    echo "--------------------------"
    exit 1
fi

echo "✅ CUDA available — continuing with the normal setup."


# =============================================================================
# setup_models.sh - Configuración de RunPod
# =============================================================================

# Token actualizado según tu solicitud
HF_TOKEN="${HF_TOKEN}"
HF_TOKEN_loras="${HF_TOKEN_loras}"
COMFYUI_DIR="/workspace/ComfyUI"

 
# Fuerza los directorios temporales de descarga al volumen de 250GB (/workspace)
# en vez del disco del contenedor (15GB), que se llena con archivos grandes
# (ej. qwen_3_8b.safetensors ~16GB no cabe ni queda espacio en un disco de 15GB).
export TMPDIR="/workspace/tmp"
mkdir -p "$TMPDIR"
 


echo "================================================"
echo "  ComfyUI Model Setup — ALL IN ONE Edition"
echo "  THANKS FOR YOUR ORDER, ADRIANFIVERR"
echo "================================================"

# PASO 1: Persistencia de ComfyUI
if [ ! -f "${COMFYUI_DIR}/main.py" ]; then
    echo "[ Copiando ComfyUI base a /workspace... ]"
    mkdir -p ${COMFYUI_DIR}
    cp -rn /ComfyUI/. ${COMFYUI_DIR}/
fi

# PASO 2: Preparar Directorios
mkdir -p ${COMFYUI_DIR}/models/loras \
         ${COMFYUI_DIR}/models/checkpoints \
         ${COMFYUI_DIR}/models/diffusion_models \
         ${COMFYUI_DIR}/models/text_encoders \
         ${COMFYUI_DIR}/models/upscale_models \
         ${COMFYUI_DIR}/models/SEEDVR2 \
         ${COMFYUI_DIR}/models/vae \
         ${COMFYUI_DIR}/models/ultralytics/bbox \
         ${COMFYUI_DIR}/models/ultralytics/segm \
         ${COMFYUI_DIR}/models/loras/ \
         ${COMFYUI_DIR}/models/sams \
         ${COMFYUI_DIR}/custom_nodes/ComfyUI_essentials/luts  \
         ${COMFYUI_DIR}/models/sam3  
         

# ── Funciones de descarga ─────────────────────────────────────────────────────

download_if_missing() {
    local url="$1" dest="$2" auth="$3" conns="${4:-16}"
    
    # Si el archivo ya existe y tiene contenido, salta la descarga
    if [ -f "$dest" ] && [ -s "$dest" ]; then 
        echo "✅ Ya existe: $(basename "$dest")"
        return 0
    fi
    
    local dest_dir=$(dirname "$dest")
    local file_name=$(basename "$dest")
    
    mkdir -p "$dest_dir"
    
    # ── Ruta rápida: HuggingFace usa `hf download` (Xet) — hasta ~4x más rápido
    # y sin los "Download aborted" que da aria2c en repos con muchas conexiones.
    if [[ "$url" == *"huggingface.co"* ]]; then
        echo "⬇️ Descargando (HF/Xet): $file_name"

        local repo_type=""
        local path_part="${url#*huggingface.co/}"
        path_part="${path_part%%\?*}"   # quita query string si la hay

        if [[ "$path_part" == datasets/* ]]; then
            repo_type="dataset"
            path_part="${path_part#datasets/}"
        fi

        # path_part: owner/repo/resolve/REVISION/ruta/dentro/del/repo/archivo.ext
        local repo=$(echo "$path_part" | cut -d/ -f1-2)
        local file_in_repo=$(echo "$path_part" | cut -d/ -f5-)   # se salta owner/repo/resolve/REVISION

        local tmp_dir=$(mktemp -d)
        local hf_opts=(download "$repo" "$file_in_repo" --local-dir "$tmp_dir")
        [ -n "$repo_type" ] && hf_opts+=(--repo-type "$repo_type")
        [ -n "$auth" ] && hf_opts+=(--token "$auth")

        HF_XET_HIGH_PERFORMANCE=1 hf "${hf_opts[@]}"
        local status=$?

        if [ $status -eq 0 ] && [ -f "$tmp_dir/$file_in_repo" ]; then
            mv "$tmp_dir/$file_in_repo" "$dest"
            rm -rf "$tmp_dir"
            echo "✅ Descarga completada: $file_name"
            return 0
        else
            rm -rf "$tmp_dir"
            echo "⚠️  hf download falló, reintentando con aria2c: $file_name"
            # cae al bloque de aria2c de abajo
        fi
    fi

    echo "⬇️ Descargando (aria2c): $file_name (conexiones: $conns)"

    # Opciones comunes para optimizar la velocidad y estabilidad en aria2c
    # $conns controla -x/-s: bájalo (ej. 4) para hosts que limitan conexiones
    # concurrentes por archivo (verás "Download aborted" repetido si es el caso)
    local aria2_opts=(
            "-x" "$conns"              # Máximo de conexiones por servidor permitidas
            "-s" "$conns"              # Máximo de particiones
            "-k" "50M"                 # Ideal para archivos masivos, divide en trozos más grandes
            "--disk-cache=256M"        # USA TU RAM: Mantiene las descargas en memoria antes de escribirlas al disco (crucial para 1 Gbps)
            "--file-allocation=falloc" # Reserva los 20GB instantáneamente en el disco en lugar de hacerlo poco a poco
            "-c"                       # Continuar descargas interrumpidas
            "--max-tries=8"            
            "--retry-wait=5"           
            "--timeout=60"             
            "--console-log-level=warn" 
            "--summary-interval=5"     
            "-d" "$dest_dir" 
            "-o" "$file_name"
    )
    
    # Ejecuta aria2c usando array para evitar problemas de comillas/espacios
    if [ -n "$auth" ]; then
        aria2c --header="Authorization: Bearer $auth" "${aria2_opts[@]}" "$url"
    else
        aria2c "${aria2_opts[@]}" "$url"
    fi

    # Manejo de errores: verifica que aria2c terminó exitosamente (código 0)
    if [ $? -eq 0 ]; then
        echo "✅ Descarga completada: $file_name"
    else
        echo "❌ Error al descargar: $file_name"
        return 1
    fi
}


download_gdown_if_missing() {
    local id="$1" dest="$2" type="$3"
    
    if [ "$type" = "folder" ]; then
        # LÓGICA PARA CARPETAS
        # Verifica si el destino es un directorio (-d) y si no está vacío
        if [ -d "$dest" ] && [ "$(ls -A "$dest" 2>/dev/null)" ]; then
            echo "  Carpeta ya existe y tiene archivos: $(basename "$dest")"
            return 0;
        fi
        
        echo "  Descargando CARPETA desde Drive: $(basename "$dest")"
        gdown --folder "$id" -O "$dest"
        
    else
        # LÓGICA PARA ARCHIVOS (Tu código original)
        # Verifica si el archivo existe (-f) y pesa más de 5MB
        if [ -f "$dest" ] && [ $(find "$dest" -type f -size +5M 2>/dev/null) ]; then 
            return 0; 
        fi
        
        echo "  Descargando ARCHIVO desde Drive: $(basename "$dest")"
        gdown "$id" -O "$dest"
    fi
}

download_hf_repo() {
    local repo="$1" dest_dir="$2"
    echo "  Descargando repo HF: $repo en $dest_dir"
    HF_TOKEN=${HF_TOKEN} huggingface-cli download "$repo" --local-dir "$dest_dir" --local-dir-use-symlinks False
}

download_hf_repo_aria2c() {
    local repo="$1" dest_dir="$2" auth="$3"

    # 1. Autoinstalación de 'jq' si no existe
    if ! command -v jq &> /dev/null; then
        echo "⚙️ 'jq' no encontrado. Instalando automáticamente..."
        
        # Evita que apt pida confirmaciones o menús interactivos que congelen el script
        export DEBIAN_FRONTEND=noninteractive 
        
        # Actualiza las listas e instala jq de forma silenciosa
        apt-get update -qq && apt-get install -y jq > /dev/null 2>&1
        
        # Verifica si la instalación fue exitosa
        if ! command -v jq &> /dev/null; then
            echo "❌ No se pudo instalar 'jq' automáticamente. Abortando."
            return 1
        fi
        echo "✅ 'jq' instalado correctamente."
    fi

    echo "🔍 Listando archivos del repositorio: $repo"
    
    # 2. Manejo dinámico del token de seguridad
    local curl_cmd=(curl -s -f)
    if [ -n "$auth" ]; then
        curl_cmd+=(-H "Authorization: Bearer $auth")
    fi

    # 3. Consulta a la API
    local files
    files=$("${curl_cmd[@]}" "https://huggingface.co/api/models/$repo" | jq -r '.siblings[].rfilename 2>/dev/null')

    # 4. Validación estricta de errores
    if [ $? -ne 0 ] || [ -z "$files" ] || [ "$files" = "null" ]; then
        echo "❌ No se encontraron archivos o acceso denegado (Revisa el nombre del repo y tu token HF)."
        return 1
    fi

    echo "📦 Archivos encontrados. Iniciando descarga por lotes..."

    # 5. Bucle de descarga
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        
        local url="https://huggingface.co/$repo/resolve/main/$file"
        local dest="$dest_dir/$file"
        
        download_if_missing "$url" "$dest" "$auth"
        
    done <<< "$files"
    
    echo "✅ Repositorio procesado completamente: $repo"
}



echo "Instalando huggingface_hub..."
pip install -U huggingface_hub

echo "Auth with Hugging Face..."
# Usamos el comando de Python para el login con el token proporcionado
python3 -c "from huggingface_hub import login; login(token='$HF_TOKEN')"

# ── SECCIÓN DE DESCARGAS MODELOS DE VIDEO  ─────────────────────────


echo "[ ------- Downloading Diffusion Models -------]"
cd ${COMFYUI_DIR}/models/diffusion_models && rm -rf split_files/
download_if_missing "https://huggingface.co/exjadev/diffusion_models/resolve/main/DasiwaWAN22I2V14BLightspeed_snatchkissHighV11.safetensors" \
    "DasiwaWAN22I2V14BLightspeed_snatchkissHighV11.safetensors" "$HF_TOKEN"

download_if_missing "https://huggingface.co/exjadev/diffusion_models/resolve/main/DasiwaWAN22I2V14BLightspeed_snatchkissLowV11.safetensors" \
    "DasiwaWAN22I2V14BLightspeed_snatchkissLowV11.safetensors" "$HF_TOKEN"



echo "[ Text Encoders ]"
cd ${COMFYUI_DIR}/models/text_encoders && rm -rf split_files/

download_if_missing "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" \
    "umt5_xxl_fp8_e4m3fn_scaled.safetensors" "$HF_TOKEN"


# ------------------------------ LORAS ---
echo "[ LoRAs ]"
cd ${COMFYUI_DIR}/models/loras && rm -rf split_files/
download_if_missing "https://huggingface.co/Serenak/chilloutmix/resolve/main/DR34ML4Y_I2V_14B_LOW_V2.safetensors" \
    "DR34ML4Y_I2V_14B_LOW_V2.safetensors" "$HF_TOKEN"
download_if_missing "https://huggingface.co/Serenak/chilloutmix/resolve/main/DR34ML4Y_I2V_14B_HIGH_V2.safetensors" \
    "DR34ML4Y_I2V_14B_HIGH_V2.safetensors" "$HF_TOKEN"

echo "[ Character LoRas ]"
cd ${COMFYUI_DIR}/models/loras && rm -rf split_files/
# -----------KLEIN ----------------
download_if_missing "https://huggingface.co/exjadev/KLEIN-ad_ape_v01/resolve/main/KLEIN_ad_ape_v04/KLEIN_ad_ape_v04_000002100.safetensors" \
    "character/KLEIN-ad_ape_v01/KLEIN_ad_ape_v04/KLEIN_ad_ape_v04_000002100.safetensors" "$HF_TOKEN"
# ----------- KREA ----------------
download_if_missing "https://huggingface.co/exjadev/KREA-ad_ape_v01/resolve/main/Krea_ad_ape_v02/Krea_ad_ape_v02_000001800.safetensors" \
    "character/KREA-ad_ape_v01/Krea_ad_ape_v02/Krea_ad_ape_v02_000001800.safetensors" "$HF_TOKEN"
download_if_missing "https://huggingface.co/exjadev/KREA-ad_ape_v01/resolve/main/Krea_ad_ape_v02/Krea_ad_ape_v02_000002250.safetensors" \
    "character/KREA-ad_ape_v01/Krea_ad_ape_v02/Krea_ad_ape_v02_000002250.safetensors" "$HF_TOKEN"
# ----------- ZIMAGE ----------------
download_if_missing "https://huggingface.co/exjadev/ZIMAGE-ad_ape-v01/resolve/main/ad_ape_v01/ad_ape_v01_000001800.safetensors" \
    "character/ZIMAGE-ad_ape-v01/ad_ape_v01/ad_ape_v01_000001800.safetensors" "$HF_TOKEN"
download_if_missing "https://huggingface.co/exjadev/ZIMAGE-ad_ape-v01/resolve/main/ad_ape_v01/ad_ape_v01_000002100.safetensors" \
    "character/ZIMAGE-ad_ape-v01/ad_ape_v01/ad_ape_v01_000002100.safetensors" "$HF_TOKEN"
download_if_missing "https://huggingface.co/exjadev/ZIMAGE-ad_ape-v01/resolve/main/ad_ape_v01/ad_ape_v01_000002250.safetensors" \
    "character/ZIMAGE-ad_ape-v01/ad_ape_v01/ad_ape_v01_000002250.safetensors" "$HF_TOKEN"


download_if_missing "https://huggingface.co/exjadev/klein_yumi_lora_v01/resolve/main/klein_yumi_lora_v1/klein_yumi_lora_v1.safetensors" \
    "character/KLEIN-ad_ape_v01/klein_yumi_lora_v1/klein_yumi_lora_v1.safetensors" "$HF_TOKEN"

download_if_missing "https://huggingface.co/exjadev/krea_yumi_lora_v01/resolve/main/krea_yumi_lora_v1/krea_yumi_lora_v1_000002250.safetensors" \
    "character/KREA-ad_ape_v01/krea_yumi_lora_v1/krea_yumi_lora_v1_000002250.safetensors" "$HF_TOKEN"


download_if_missing "https://huggingface.co/exjadev/zimage_yumi_lora_v01/resolve/main/yumi_lora_v01/yumi_lora_v01_000002250.safetensors" \
    "character/ZIMAGE-ad_ape-v01/yumi_lora_v01/yumi_lora_v01_000002250.safetensors" "$HF_TOKEN"





echo "[ VAE ]"
cd ${COMFYUI_DIR}/models/vae && rm -rf split_files/
download_if_missing "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1_VAE_fp32.safetensors" \
    "Wan2_1_VAE_fp32.safetensors" "$HF_TOKEN"


# --- SAM3 ---
echo "[ ----------- Downloading SAM3 -----------  ]"
cd ${COMFYUI_DIR}/models/sam3
download_if_missing "https://huggingface.co/facebook/sam3/resolve/main/sam3.pt" \
    "sam3.pt" "$HF_TOKEN"


    # ── SAMS (ReActor/Segment Anything) ──────────────────────────────────────────
echo "[ SAM3 ]"
cd ${COMFYUI_DIR}/models/sams
download_if_missing "https://huggingface.co/datasets/Gourieff/ReActor/resolve/main/models/sams/sam_vit_b_01ec64.pth" \
    "sam_vit_b_01ec64.pth" "$HF_TOKEN"
download_if_missing "https://huggingface.co/HCMUE-Research/SAM-vit-h/resolve/main/sam_vit_h_4b8939.pth" \
    "sam_vit_h_4b8939.pth" "$HF_TOKEN"


# ── BBOX Ultralytics ──────────────────────────────────────────────────────────
echo ""
echo "[ BBOX Ultralytics ]"
cd ${COMFYUI_DIR}/models/ultralytics/bbox && rm -rf split_files/
download_if_missing "https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov8m.pt" \
    "face_yolov8m.pt" "$HF_TOKEN"
download_if_missing "https://huggingface.co/ashllay/YOLO_Models/resolve/main/bbox/female_breast-v4.2.pt" \
    "female_breast-v4.2.pt" "$HF_TOKEN"
download_if_missing "https://huggingface.co/ashllay/YOLO_Models/resolve/main/bbox/vagina-v3.2.pt" \
    "vagina-v3.2.pt" "$HF_TOKEN"
download_if_missing "https://huggingface.co/ashllay/YOLO_Models/resolve/main/bbox/full_eyes_detect_v1.pt" \
    "full_eyes_detect_v1.pt" "$HF_TOKEN"
download_if_missing "https://huggingface.co/xingren23/comfyflow-models/resolve/976de8449674de379b02c144d0b3cfa2b61482f2/ultralytics/bbox/hand_yolov8s.pt" \
    "hand_yolov8s.pt" "$HF_TOKEN"


echo "[-----------  Downloading BBOX Ultralytics SEGM -----------  ]"
cd ${COMFYUI_DIR}/models/ultralytics/segm
download_if_missing "https://huggingface.co/Bingsu/adetailer/resolve/main/person_yolov8m-seg.pt" \
    "person_yolov8m-seg.pt" "$HF_TOKEN"
download_if_missing "https://huggingface.co/24xx/segm/resolve/main/deepfashion2_yolov8s-seg.pt" \
    "deepfashion2_yolov8s-seg.pt" "$HF_TOKEN"
download_if_missing "https://huggingface.co/24xx/segm/resolve/main/hair_yolov8n-seg_60.pt" \
    "hair_yolov8n-seg_60.pt" "$HF_TOKEN"
download_if_missing "https://huggingface.co/24xx/segm/resolve/main/skin_yolov8n-seg_800.pt" \
    "skin_yolov8n-seg_800.pt" "$HF_TOKEN"



# ── SECCIÓN DE DESCARGAS MODELOS DE IMAGEN ─────────────────────────
# --- DIFFUSION MODELS ---
echo "[ ------- Downloading Diffusion Models -------]"
cd ${COMFYUI_DIR}/models/diffusion_models && rm -rf split_files/

download_if_missing "https://huggingface.co/exjadev/diffusion_models/resolve/main/krast_v20.safetensors" \
    "krast_v20.safetensors" "$HF_TOKEN"

cd ${COMFYUI_DIR}/models/diffusion_models 
download_if_missing "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/diffusion_models/z_image_turbo_bf16.safetensors" \
    "z_image_turbo_bf16.safetensors" "$HF_TOKEN"

cd ${COMFYUI_DIR}/models/diffusion_models 
download_if_missing "https://huggingface.co/black-forest-labs/FLUX.2-klein-9b-fp8/resolve/main/flux-2-klein-9b-fp8.safetensors" \
    "flux-2-klein-9b-fp8.safetensors" "$HF_TOKEN"


# --- TEXT ENCODERS ---
echo "[ Text Encoders ]"
cd ${COMFYUI_DIR}/models/text_encoders && rm -rf split_files/
download_if_missing "https://huggingface.co/AlperKTS/Krea2_FP8/resolve/main/qwen3vl_4b_fp8_scaled.safetensors" \
    "qwen3vl_4b_fp8_scaled.safetensors" "$HF_TOKEN"
download_if_missing "https://huggingface.co/unsloth/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-UD-Q8_K_XL.gguf" \
    "Qwen3-4B-UD-Q8_K_XL.gguf" "$HF_TOKEN"
download_if_missing "https://huggingface.co/Comfy-Org/vae-text-encorder-for-flux-klein-9b/resolve/main/split_files/text_encoders/qwen_3_8b.safetensors" \
    "qwen_3_8b.safetensors" "$HF_TOKEN"


# --- VAE ---
echo "[ VAE ]"
cd ${COMFYUI_DIR}/models/vae && rm -rf split_files/
download_if_missing "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/ae.safetensors" \
    "ae.safetensors" "$HF_TOKEN"
download_if_missing "https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/vae/flux2-vae.safetensors" \
    "flux2-vae.safetensors" "$HF_TOKEN"
download_if_missing "https://civitai.red/api/download/models/3068442?fileId=2947164&token=e3a803e3831ec4832fd75d014b2d385e" \
    "krea2RealVae_v10.safetensors" "$HF_TOKEN"

(
# ------------------------------ LORAS ---
echo "[ LoRAs ]"
cd ${COMFYUI_DIR}/models/loras && rm -rf recipes/
# Civitai filters & loras
download_if_missing "https://civitai.red/api/download/models/3067151?type=Model&format=SafeTensor&token=e3a803e3831ec4832fd75d014b2d385e" \
    "krea2filterbypass3.safetensors"

download_if_missing "https://civitai.red/api/download/models/3113304?type=Model&format=SafeTensor&token=e3a803e3831ec4832fd75d014b2d385e" \
    "JPEGCompressionKrea2_c1-st5000.safetensors"

download_if_missing "https://civitai.red/api/download/models/2749020?type=Model&format=SafeTensor&token=e3a803e3831ec4832fd75d014b2d385e" \
    "Klein-NippleDiffusion.safetensors"

download_if_missing "https://civitai.red/api/download/models/2960754?type=Model&format=SafeTensor&token=e3a803e3831ec4832fd75d014b2d385e" \
    "Klein-PussyDiffusion.safetensors"

download_if_missing "https://civitai.red/api/download/models/2617751?type=Model&format=SafeTensor&token=e3a803e3831ec4832fd75d014b2d385e" \
    "Klein-Realistic_Nudes.safetensors"
download_if_missing "https://civitai.red/api/download/models/2441730?type=Model&format=SafeTensor&token=e3a803e3831ec4832fd75d014b2d385e" \
    "blowjob_I2V_14B_HIGH_V2.safetensors" 

download_if_missing "https://civitai.red/api/download/models/2445044?type=Model&format=SafeTensor&token=e3a803e3831ec4832fd75d014b2d385e" \
    "blowjob_I2V_14B_LOW_V2.safetensors" 

download_if_missing "https://civitai.red/api/download/models/2209354?type=Model&format=SafeTensor&token=e3a803e3831ec4832fd75d014b2d385e" \
    "bounce_test_HighNoise-000005.safetensors" 

download_if_missing "https://civitai.red/api/download/models/2209344?type=Model&format=SafeTensor&token=e3a803e3831ec4832fd75d014b2d385e" \
    "bounce_test_LowNoise-000005.safetensors" 

download_if_missing "https://civitai.red/api/download/models/2273468?type=Model&format=SafeTensor&token=e3a803e3831ec4832fd75d014b2d385e" \
    "slop_twerk_HighNoise_merged3_7_v2.safetensors" 

download_if_missing "https://civitai.red/api/download/models/2273467?type=Model&format=SafeTensor&token=e3a803e3831ec4832fd75d014b2d385e" \
    "slop_twerk_LowNoise_merged3_7_v2.safetensors" 

download_if_missing "https://civitai.red/api/download/models/1973462?type=Model&format=SafeTensor&token=e3a803e3831ec4832fd75d014b2d385e" \
    "Wan_facial_t2v.safetensors" 
    
download_if_missing "https://civitai.red/api/download/models/2441730?type=Model&format=SafeTensor&token=e3a803e3831ec4832fd75d014b2d385e" \
    "DaSiWa_Wan22_High_Deepthroat_v11.safetensors" 



# ── Upscaler Models ──────────────────────────────────────────────────────────
echo ""
echo "[ -----------  Downloading UUpscaling  Models  ----------- ]"
cd ${COMFYUI_DIR}/models/upscale_models && rm -rf split_files/
download_if_missing "https://huggingface.co/FacehugmanIII/4x_foolhardy_Remacri/resolve/main/4x_foolhardy_Remacri.pth" \
    "4x_foolhardy_Remacri.pth" "$HF_TOKEN"
download_if_missing "https://huggingface.co/Kim2091/UltraSharpV2/resolve/main/4x-UltraSharpV2.safetensors" \
    "4x-UltraSharpV2.safetensors" "$HF_TOKEN"


download_gdown_if_missing "1N3ysO2IWkouzy4aFONLgYUjaUMrLz8AB" "4xFFHQDAT.pth"

echo "[ -----------  Creating BROKEN_NCNN  ----------- ]"
cd ${COMFYUI_DIR}/models/upscale_models/
megadl 'https://mega.nz/folder/Xc4wnC7T#yUS5-9-AbRxLhpdPW_8f2w'


# --- LUTS ---
# ── Luts  ──────────────────────────────────────────────────────────
echo "[ VAE ]"
cd ${COMFYUI_DIR}/custom_nodes/ComfyUI_essentials/luts 
echo ""
echo "[ ----------Downloading LUTs --------------]"
download_gdown_if_missing "1GJEhRrycKwMINkgicw_GjQbjuwdqRJ9P" "LUTs" "folder"



) &


cd ${COMFYUI_DIR}
# 2. Escribir los permisos de los modelos en la lista blanca
echo "4x-UltraSharpV2.safetensors" >> /workspace/ComfyUI/user/default/ComfyUI-Impact-Subpack/model-whitelist.txt
echo "4xFFHQDAT.pth" >> /workspace/ComfyUI/user/default/ComfyUI-Impact-Subpack/model-whitelist.txt
echo "4x_foolhardy_Remacri.pth" >> /workspace/ComfyUI/user/default/ComfyUI-Impact-Subpack/model-whitelist.txt
echo "BROKEN_NCNN/4x-ClearRealityV1-fp16.bin" >> /workspace/ComfyUI/user/default/ComfyUI-Impact-Subpack/model-whitelist.txt
echo "4x-ClearRealityV1.pth" >> /workspace/ComfyUI/user/default/ComfyUI-Impact-Subpack/model-whitelist.txt

# Autorización para el modelo SwinIR
echo "003_realSR_BSRGAN_DFOWMFC_s64w8_SwinIR-L_x4_GAN.pth" >> /workspace/ComfyUI/user/default/ComfyUI-Impact-Subpack/model-whitelist.txt


# ── Lanzar ComfyUI ────────────────────────────────────────────────────────────
echo ""
echo "================================================"
echo "  Setup full. starting ComfyUI..."
echo "================================================"

chmod -R 777 /workspace/ComfyUI

exec python /workspace/ComfyUI/main.py --listen 0.0.0.0 --port 8188 --enable-manager  