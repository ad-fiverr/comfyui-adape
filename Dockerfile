FROM ls250824/run-comfyui-wan2:30072026

ENV DEBIAN_FRONTEND=noninteractive
# ComfyUI ya esta en /ComfyUI en la imagen base
# setup_models.sh lo copiara a /workspace/ComfyUI al primer arranque

RUN apt-get update -qq && apt-get install -y -qq git wget && \
    pip install -q gdown && \
    rm -rf /var/lib/apt/lists/*


# --- Constraint global ANTES de instalar cualquier custom node ---
# Así, el pip install -r requirements.txt de ComfyUI-LTXVideo (y de
# cualquier otro nodo) respeta este límite desde su primera instalación,
# en vez de instalar una versión rota y luego corregirla.
RUN echo "kornia==0.6.12" > /etc/pip-constraints.txt
ENV PIP_CONSTRAINT=/etc/pip-constraints.txt


# Custom Nodes en /ComfyUI (se copian al workspace en el primer arranque)
RUN cd /ComfyUI/custom_nodes && \
    rm -rf rgthree-comfy ComfyUI-Impact-Pack ComfyUI_essentials ComfyUI-GGUF ComfyUI-Impact-Subpack cg-use-everywhere ComfyMath ComfyUI-mxToolkit comfyui-crystools ComfyUI_LayerStyle ComfyUI_Fill-Nodes ComfyUI-Image-Saver ComfyUI-AdvancedLivePortrait ComfyUI-WanVideoWrapper ComfyUI-Login ComfyUI-login Vantage-Nodes ComfyUI-Gemini ComfyUI-LTXVideo LanPaint ComfyUI_Comfyroll_CustomNodes ComfyUI_Eclipse ComfyUI-Pixaroma CRT-Nodes ComfyUI-CRZnodes ComfyUI-RBG-SmartSeedVariance ComfyUI_SaveImageWithMetaDataUniversal ComfyUI-DaSiWa-Nodes ComfyUI-SeedVR2_VideoUpscaler ComfyUI-QwenImageWanBridge && \ 
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
    git clone --depth=1 https://github.com/xxmjskxx/ComfyUI_SaveImageWithMetaDataUniversal.git  && \
    git clone --depth=1 https://github.com/darksidewalker/ComfyUI-DaSiWa-Nodes.git && \
    git clone --depth=1 https://github.com/fblissjr/ComfyUI-QwenImageWanBridge.git && \
    git clone --depth=1 https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler.git 
    

RUN for dir in rgthree-comfy ComfyUI-Impact-Pack ComfyUI_essentials ComfyUI-GGUF ComfyUI-Impact-Subpack cg-use-everywhere ComfyMath ComfyUI-Custom-Scripts ComfyUI-mxToolkit comfyui-crystools ComfyUI_LayerStyle ComfyUI_Fill-Nodes ComfyUI-Image-Saver ComfyUI-AdvancedLivePortrait ComfyUI-WanVideoWrapper Vantage-Nodes ComfyUI-Gemini ComfyUI-LTXVideo LanPaint ComfyUI_Comfyroll_CustomNodes ComfyUI_Eclipse ComfyUI-Pixaroma CRT-Nodes ComfyUI-CRZnodes ComfyUI-RBG-SmartSeedVariance ComfyUI_SaveImageWithMetaDataUniversal ComfyUI-DaSiWa-Nodes ComfyUI-SeedVR2_VideoUpscaler ComfyUI-QwenImageWanBridge; do \
      REQ="/ComfyUI/custom_nodes/${dir}/requirements.txt"; \
      if [ -f "$REQ" ]; then pip install -q -r "$REQ"; fi; \
    done


RUN rm -rf /ComfyUI/custom_nodes/ComfyUI-Login /ComfyUI/custom_nodes/ComfyUI-login


RUN mkdir -p /ComfyUI/user/default/workflows
COPY Wan22_FF2LF_fastfidelity.json /ComfyUI/user/default/workflows/WAN22-I2V-workflow.json
COPY Krea2_T2I_workflow.json /ComfyUI/user/default/workflows/Krea-T2I-workflow.json
COPY Zimage-T2I-workflow.json /ComfyUI/user/default/workflows/Zimage-T2I-workflow.json
COPY Create-Prompts-workflow.json /ComfyUI/user/default/workflows/Create-Prompts-workflow.json
COPY Klein-Inpainting-workflow.json /ComfyUI/user/default/workflows/Klein-Inpainting-workflow.json
COPY Krea-I2I-workflow.json /ComfyUI/user/default/workflows/Krea-I2I-workflow.json
COPY Zimage-upscaler-workflow.json /ComfyUI/user/default/workflows/Zimage-upscaler-workflow.json

RUN apt-get update -qq && apt-get install -y -qq git wget dos2unix aria2 megatools && \
    pip install -q gdown huggingface_hub comfyui-manager && \
    rm -rf /var/lib/apt/lists/*

ARG HF_TOKEN
ENV HF_TOKEN=${HF_TOKEN}

COPY setup_models.sh /setup_models.sh
RUN dos2unix /setup_models.sh && chmod +x /setup_models.sh


EXPOSE 8188
CMD ["/setup_models.sh"]