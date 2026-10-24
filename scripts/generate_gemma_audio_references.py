"""Offline reference generation only; never imported by Muesli or its build.

Install the isolated tools listed in Context/gemma-audio-parity-2026-10-24.md.
The original forward methods execute unchanged. Hooks copy outputs; they do
not replace modules or alter tensors used by the original encoder. FP32 mode
only upcasts the checkpoint values in memory and never rewrites model files.
"""
import argparse, hashlib, inspect, json, pathlib, platform
import numpy as np
import torch
from safetensors import safe_open
from safetensors.torch import save_file
from transformers.models.gemma4.configuration_gemma4 import Gemma4AudioConfig
from transformers.models.gemma4.modeling_gemma4 import Gemma4AudioModel
from transformers.models.gemma4.feature_extraction_gemma4 import Gemma4AudioFeatureExtractor

p=argparse.ArgumentParser(); p.add_argument('--model',required=True); p.add_argument('--layout',choices=['mlx','huggingFace'],required=True); p.add_argument('--output',required=True); p.add_argument('--precision',choices=['checkpoint','float32'],default='checkpoint'); p.add_argument('--device',choices=['cpu','mps'],default='cpu'); a=p.parse_args()
root=pathlib.Path(a.model); out=pathlib.Path(a.output); out.mkdir(parents=True,exist_ok=True)
torch.set_num_threads(4)
def digest(p):
    h=hashlib.sha256()
    with open(p,'rb') as f:
        for b in iter(lambda:f.read(4*1024*1024),b''):h.update(b)
    return h.hexdigest()
# Refuse to label a different implementation with the pinned revision.
for cls, expected in [
    (Gemma4AudioModel, "a6d2bf3da6693806d91c29c8da34378565d6f1159cc2a483308228ded411ea55"),
    (Gemma4AudioFeatureExtractor, "40545340a144aad4d74c6cedb4eae5daa4efd54ae432649583e19b5d756c02c7"),
]:
    if digest(inspect.getfile(cls)) != expected:
        raise RuntimeError("Reference source does not match the pinned Transformers implementation")
config=json.loads((root/'config.json').read_text())['audio_config']; conf=Gemma4AudioConfig(**config)
with torch.device('meta'): model=Gemma4AudioModel(conf)
state={}; prefix='audio_tower.' if a.layout=='mlx' else 'model.audio_tower.'
with safe_open(root/'model.safetensors',framework='pt',device='cpu') as sf:
    for k in sf.keys():
        if not k.startswith(prefix):continue
        v=sf.get_tensor(k); key=k[len(prefix):]
        if a.layout=='mlx' and key.endswith('.conv.weight'):v=v.permute(0,3,1,2).contiguous()
        elif a.layout=='mlx' and key.endswith('.depthwise_conv1d.weight'):v=v.permute(0,2,1).contiguous()
        state[key]=v
model.load_state_dict(state,strict=True,assign=True); model.eval()
# Meta-created relative-position buffer is not in state_dict.
model.rel_pos_enc=type(model.rel_pos_enc)(conf)
for layer in model.layers: layer.self_attn.softcap=torch.tensor(conf.attention_logit_cap)

if a.precision=='float32': model.float()
model.to(a.device)
print('Loaded',len(state),'tensors',flush=True)
trace={}
def capture(name,subsample=False):
    def hook(mod,args,result):
        if subsample:
            trace[name]=result[0].permute(0,2,3,1).float().contiguous().clone()
            trace[name+'_mask']=result[1][0].bool().clone()
        else: trace[name]=result.float().contiguous().clone()
    return hook
for i in range(2):getattr(model.subsample_conv_projection,f'layer{i}').register_forward_hook(capture(f'subsample{i}',True))
model.subsample_conv_projection.input_proj_linear.register_forward_hook(capture('input_projection'))
for i,layer in enumerate(model.layers):layer.register_forward_hook(capture(f'layer{i}'))
fe=Gemma4AudioFeatureExtractor()
feature=dict(sampleRate=16000,frameLength=320,hopLength=160,fftLength=512,melBins=128,minimumFrequency=0,maximumFrequency=8000,melFloor=.001,preemphasis=0,htkPreemphasis=True,inputScale=1,padToMultiple=128,maximumSamples=480000)
hashes=dict(modelSHA256=digest(root/'model.safetensors'),configSHA256=digest(root/'config.json'))
for case,n in [('masked',319),('masked_block',7839),('boundary',641),('silence',16000),('multitone',32017)]:
    t=np.arange(n,dtype=np.float64)/16000
    samples=np.zeros(n,dtype=np.float32) if case=='silence' else ((.15*np.sin(2*np.pi*440*t)+.07*np.sin(2*np.pi*1733*t))*(.6+.4*np.sin(2*np.pi*3*t))).astype(np.float32)
    batch=fe([samples],return_tensors='pt'); trace.clear()
    trace['samples']=torch.from_numpy(samples); trace['mel']=batch['input_features'].clone(); trace['mel_mask']=batch['input_features_mask'][0].bool().clone()
    with torch.inference_mode(): result=model(batch['input_features'].to(a.device),attention_mask=batch['input_features_mask'].to(a.device))
    trace['encoder']=result.last_hidden_state.float().contiguous().clone(); trace['encoder_mask']=result.attention_mask[0].bool().clone()
    dest=out/case; dest.mkdir(exist_ok=True); save_file({k:v.cpu() for k,v in trace.items()},str(dest/'reference.safetensors'))
    # BF16 keeps its initial diagnostic budget. FP32 uses 5e-4 absolute + 1e-4 relative:
    # the original CPU/MPS control itself differs by 3.49e-4 on final features.
    # Earlier failures at 1e-4 are retained in the experiment logs.
    stages=[dict(name=k,absoluteTolerance=0 if k.endswith('_mask') else (1e-5 if k=='mel' else (5e-4 if a.precision=='float32' else .02)),relativeTolerance=0 if k.endswith('_mask') else (1e-6 if k=='mel' else (1e-4 if a.precision=='float32' else .02))) for k in trace if k!='samples']
    manifest=dict(precision=a.precision,weightLayout=a.layout,producer=f'Hugging Face Gemma4AudioModel, torch {torch.__version__}, {a.device} {platform.machine()}, {a.precision} precision',referenceCommit='50e35cc0ca18ec19b80653690de553e6decf74f5',**hashes,tensorsSHA256=digest(dest/'reference.safetensors'),featureConfiguration=feature,sampleRate=16000,stages=stages)
    (dest/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n'); print(case,{k:list(v.shape) for k,v in trace.items()},flush=True)
