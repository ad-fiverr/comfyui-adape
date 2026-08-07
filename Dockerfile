FROM nvidia/cuda:12.8.1-cudnn-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

RUN apt-get update -qq && apt-get install -y -qq \
    git wget curl dos2unix aria2 megatools \
    python3.11 python3.11-venv python3.11-distutils \
    && rm -rf /var/lib/apt/lists/*

RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 && \
    update-alternatives --install /usr/bin/python python /usr/bin/python3.11 1

# Bootstrap pip directamente para 3.11 (python3-pip del sistema instala para 3.10, no sirve aquí)
RUN curl -sS https://bootstrap.pypa.io/get-pip.py | python3.11

# --- PyTorch: versión explícita, controlada por ti (no heredada de un tercero) ---
# cu128 confirmado funcional en tus pruebas con 3090 Ti y 4090.
# Si más adelante RunPod resuelve el soporte de Blackwell, prueba cambiar a cu130.
RUN pip install --no-cache-dir torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cu128

# --- Clonar ComfyUI directamente desde el repo oficial ---
RUN git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git /ComfyUI
RUN pip install --no-cache-dir -r /ComfyUI/requirements.txt

# --- Constraint global ANTES de instalar cualquier custom node ---
RUN echo "kornia==0.6.12" > /etc/pip-constraints.txt
ENV PIP_CONSTRAINT=/etc/pip-constraints.txt


# --- Custom Nodes ---
RUN cd /ComfyUI/custom_nodes && \
    git clone --depth=1 https://github.com/rgthree/rgthree-comfy.git && \
    git clone --depth=1 https://github.com/ltdrdata/ComfyUI-Impact-Pack.git && \
    git clone --depth=1 https://github.com/cubiq/ComfyUI_essentials.git && \
    git clone --depth=1 https://github.com/city96/ComfyUI-GGUF.git && \
    git clone --depth=1 https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git && \
    git clone --depth=1 https://github.com/evanspearman/ComfyMath.git && \
    git clone --depth=1 https://github.com/chrisgoringe/cg-use-everywhere.git && \
    git clone --depth=1 https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git && \
    git clone --depth=1 https://github.com/Smirnov75/ComfyUI-mxToolkit.git && \
    git clone --depth=1 https://github.com/crystian/comfyui-crystools.git && \
    git clone --depth=1 https://github.com/chflame163/ComfyUI_LayerStyle.git && \
    git clone --depth=1 https://github.com/filliptm/ComfyUI_Fill-Nodes.git && \
    git clone --depth=1 https://github.com/farizrifqi/ComfyUI-Image-Saver.git && \
    git clone --depth=1 https://github.com/PowerHouseMan/ComfyUI-AdvancedLivePortrait.git && \
    git clone --depth=1 https://github.com/vantagewithai/Vantage-Nodes.git && \
    git clone --depth=1 https://github.com/Visionatrix/ComfyUI-Gemini.git && \
    git clone --depth=1 https://github.com/Lightricks/ComfyUI-LTXVideo.git && \
    git clone --depth=1 https://github.com/kijai/ComfyUI-WanVideoWrapper.git && \
    git clone --depth=1 https://github.com/scraed/LanPaint.git && \
    git clone --depth=1 https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes.git && \
    git clone --depth=1 https://github.com/r-vage/ComfyUI_Eclipse.git && \
    git clone --depth=1 https://github.com/pixaroma/ComfyUI-Pixaroma.git && \
    git clone --depth=1 https://github.com/PGCRT/CRT-Nodes.git && \
    git clone --depth=1 https://github.com/CoreyCorza/ComfyUI-CRZnodes.git && \
    git clone --depth=1 https://github.com/RamonGuthrie/ComfyUI-RBG-SmartSeedVariance.git && \
    git clone --depth=1 https://github.com/xxmjskxx/ComfyUI_SaveImageWithMetaDataUniversal.git && \
    git clone --depth=1 https://github.com/darksidewalker/ComfyUI-DaSiWa-Nodes.git && \
    git clone --depth=1 https://github.com/fblissjr/ComfyUI-QwenImageWanBridge.git && \
    git clone --depth=1 https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler.git && \
    git clone --depth=1 https://github.com/kijai/ComfyUI-KJNodes.git && \
    git clone --depth=1 https://github.com/yolain/ComfyUI-Easy-Use.git && \
    git clone --depth=1 https://github.com/IAMCCS/IAMCCS-nodes.git && \
    git clone --depth=1 https://github.com/ClownsharkBatwing/RES4LYF.git
 
RUN for dir in rgthree-comfy ComfyUI-Impact-Pack ComfyUI_essentials ComfyUI-GGUF ComfyUI-Impact-Subpack cg-use-everywhere ComfyMath ComfyUI-Custom-Scripts ComfyUI-mxToolkit comfyui-crystools ComfyUI_LayerStyle ComfyUI_Fill-Nodes ComfyUI-Image-Saver ComfyUI-AdvancedLivePortrait ComfyUI-WanVideoWrapper Vantage-Nodes ComfyUI-Gemini ComfyUI-LTXVideo LanPaint ComfyUI_Comfyroll_CustomNodes ComfyUI_Eclipse ComfyUI-Pixaroma CRT-Nodes ComfyUI-CRZnodes ComfyUI-RBG-SmartSeedVariance ComfyUI_SaveImageWithMetaDataUniversal ComfyUI-DaSiWa-Nodes ComfyUI-SeedVR2_VideoUpscaler ComfyUI-QwenImageWanBridge ComfyUI-KJNodes ComfyUI-Easy-Use IAMCCS-nodes RES4LYF; do \
      REQ="/ComfyUI/custom_nodes/${dir}/requirements.txt"; \
      if [ -f "$REQ" ]; then pip install -q -r "$REQ"; fi; \
    done


RUN cd /ComfyUI/custom_nodes/ComfyUI-Impact-Pack && python3 install.py || true    
RUN rm -rf /ComfyUI/custom_nodes/ComfyUI-Login /ComfyUI/custom_nodes/ComfyUI-login

# --- Workflows ---
RUN mkdir -p /ComfyUI/user/default/workflows
COPY Wan22_FF2LF_fastfidelity.json /ComfyUI/user/default/workflows/WAN22-I2V-workflow.json
COPY Krea2_T2I_workflow.json /ComfyUI/user/default/workflows/Krea-T2I-workflow.json
COPY Zimage-T2I-workflow.json /ComfyUI/user/default/workflows/Zimage-T2I-workflow.json
COPY Create-Prompts-workflow.json /ComfyUI/user/default/workflows/Create-Prompts-workflow.json
COPY Klein-Inpainting-workflow.json /ComfyUI/user/default/workflows/Klein-Inpainting-workflow.json
COPY Krea-I2I-workflow.json /ComfyUI/user/default/workflows/Krea-I2I-workflow.json
COPY Zimage-upscaler-workflow.json /ComfyUI/user/default/workflows/Zimage-upscaler-workflow.json

RUN pip install --no-cache-dir gdown huggingface_hub comfyui-manager

ARG HF_TOKEN
ENV HF_TOKEN=${HF_TOKEN}

COPY setup_models.sh /setup_models.sh
RUN dos2unix /setup_models.sh && chmod +x /setup_models.sh

EXPOSE 8188
CMD ["/setup_models.sh"]