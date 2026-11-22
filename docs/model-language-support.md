# Dictation model language discovery

Models → Dictation searches model names and confirmed spoken-input languages.
Coverage lives in `ModelLanguageSupport.swift`, alongside `BackendOption`, and
is independent of the active language preference or downloaded assets. Searching
does not change either preference. Results include compatible experimental and
streaming models that can also perform dictation.

The metadata reuses the runtime's language definitions:

| Models | Coverage source |
| --- | --- |
| Parakeet Unified, v2, MedASR, English Whisper | English only |
| Parakeet v3, Redux, Phonon | Upstream 25-language list; names from `ParakeetLanguage` |
| Multilingual Whisper | `WhisperKitLanguage.choices(for:)`; Cantonese requires large-v3 |
| Qwen3 ASR | `Qwen3AsrLanguage`, backed by the vendored runtime's language enum |
| Nemotron | `Nemotron35Language`; the runtime's supported prompt locales, excluding reserved/adaptation-only prompts |
| Cohere | `CohereTranscribeLanguage` |
| Bodhan | `BodhanLanguage.choices(for:)`; Core and Flex differ |
| Apple Speech | `SpeechTranscriber.supportedLocales`, via `AppleSpeechLanguageOption.supportedOptions()` |
| SenseVoice Small | Mandarin, Cantonese, English, Japanese, Korean |

Parakeet's [upstream supported languages](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
exclude Bosnian, Belarusian, and Serbian even though the runtime's script-filter
hint enum accepts them. Filter hints are not evidence of trained coverage.

SenseVoice Small's five-language coverage is documented in its
[upstream model card](https://huggingface.co/FunAudioLLM/SenseVoiceSmall) and
[technical report](https://arxiv.org/abs/2407.04051). The family's broader 50+
language claim must not be applied to Small.

Gemma E2B/E4B now list the 12 languages with published ASR results in Table 7
of Google's [technical report](https://arxiv.org/html/2607.02770v2). These are
explicitly labelled evaluated coverage, not an exhaustive support contract or a
validation of muesli's converted runtime. The [audio guide](https://ai.google.dev/gemma/docs/capabilities/audio)
does not enumerate an exhaustive set. The 140+ text-language claim must not be
used to populate ASR support. Unknown additional speech coverage remains unknown.

Qwen's 30 selectable languages and 22 documented dialect/accent entries are
shown separately. Dialect names are searchable discovery metadata; they never
become invented decoder language codes or automatically change preferences.

Language-code queries match codes exactly. Language-name queries also match native
and current-locale names, ignoring case and diacritics. Apple coverage uses only
reported supported locales, not a saved unsupported preference or the System
Language placeholder. Regression tests live in `BackendOptionTests`, already
registered in the CI shards.

This builds on the language-visibility idea in
[PR #737](https://github.com/Muesli-HQ/muesli/pull/737); it does not import that
PR's separate configuration fallback logging changes.

## Upstream audit — 20 November 2026

Researched with Exa across 45 search results in nine targeted searches, then
checked primary model cards, original runtime code and the Gemma technical report.
Search results overlap; 45 is not a count of unique or independently confirming
sources. The catalog below covers every current dictation model family.

### English-only variants

- [Parakeet Unified](https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml): English.
- [Parakeet v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2): English.
- [Whisper Tiny/Small/Medium .en](https://github.com/openai/whisper#available-models-and-languages): English.
- [MedASR](https://huggingface.co/google/medasr): English; training is English-only, primarily US speakers.

### Parakeet v3, Redux and Phonon-2.5 — 25 languages

Sources: [NVIDIA](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3),
[Moondream](https://huggingface.co/moondream/parakeet-redux),
[Fermion](https://www.fermionresearch.com/models/phonon-2-5/).

English (`en`), Spanish (`es`), French (`fr`), German (`de`), Italian (`it`), Portuguese (`pt`), Romanian (`ro`), Dutch (`nl`), Danish (`da`), Swedish (`sv`), Finnish (`fi`), Hungarian (`hu`), Estonian (`et`), Latvian (`lv`), Lithuanian (`lt`), Maltese (`mt`), Polish (`pl`), Czech (`cs`), Slovak (`sk`), Slovenian (`sl`), Croatian (`hr`), Russian (`ru`), Ukrainian (`uk`), Bulgarian (`bg`), Greek (`el`).

### Whisper multilingual — 99 or 100 languages

Tiny and Small expose the 99 languages below. Large Turbo adds Cantonese (`yue`),
for 100. This is the explicit per-checkpoint language-token contract used by
WhisperKit; it does not claim an older checkpoint can never recognize Cantonese
under a Chinese hint. Sources: [OpenAI tokenizer](https://github.com/openai/whisper/blob/main/whisper/tokenizer.py),
[large-v3 model card](https://huggingface.co/openai/whisper-large-v3).

Afrikaans (`af`), Albanian (`sq`), Amharic (`am`), Arabic (`ar`), Armenian (`hy`), Assamese (`as`), Azerbaijani (`az`), Bashkir (`ba`), Basque (`eu`), Belarusian (`be`), Bengali (`bn`), Bosnian (`bs`), Breton (`br`), Bulgarian (`bg`), Burmese (`my`), Catalan (`ca`), Chinese (`zh`), Croatian (`hr`), Czech (`cs`), Danish (`da`), Dutch (`nl`), English (`en`), Estonian (`et`), Faroese (`fo`), Finnish (`fi`), French (`fr`), Galician (`gl`), Georgian (`ka`), German (`de`), Greek (`el`), Gujarati (`gu`), Haitian Creole (`ht`), Hausa (`ha`), Hawaiian (`haw`), Hebrew (`he`), Hindi (`hi`), Hungarian (`hu`), Icelandic (`is`), Indonesian (`id`), Italian (`it`), Japanese (`ja`), Javanese (`jw`), Kannada (`kn`), Kazakh (`kk`), Khmer (`km`), Korean (`ko`), Lao (`lo`), Latin (`la`), Latvian (`lv`), Lingala (`ln`), Lithuanian (`lt`), Luxembourgish (`lb`), Macedonian (`mk`), Malagasy (`mg`), Malay (`ms`), Malayalam (`ml`), Maltese (`mt`), Maori (`mi`), Marathi (`mr`), Mongolian (`mn`), Nepali (`ne`), Norwegian (`no`), Norwegian Nynorsk (`nn`), Occitan (`oc`), Pashto (`ps`), Persian (`fa`), Polish (`pl`), Portuguese (`pt`), Punjabi (`pa`), Romanian (`ro`), Russian (`ru`), Sanskrit (`sa`), Serbian (`sr`), Shona (`sn`), Sindhi (`sd`), Sinhala (`si`), Slovak (`sk`), Slovenian (`sl`), Somali (`so`), Spanish (`es`), Sundanese (`su`), Swahili (`sw`), Swedish (`sv`), Tagalog (`tl`), Tajik (`tg`), Tamil (`ta`), Tatar (`tt`), Telugu (`te`), Thai (`th`), Tibetan (`bo`), Turkish (`tr`), Turkmen (`tk`), Ukrainian (`uk`), Urdu (`ur`), Uzbek (`uz`), Vietnamese (`vi`), Welsh (`cy`), Yiddish (`yi`), Yoruba (`yo`).

### Qwen3 ASR 0.6B — 30 languages plus 22 dialect/accent entries

Source: [Qwen's released-model table](https://github.com/QwenLM/Qwen3-ASR#released-models-description-and-download).
The [Core ML conversion](https://huggingface.co/FluidInference/qwen3-asr-0.6b-coreml)
identifies the same original checkpoint. Its 30-language enum matches upstream.

Chinese (`zh`), English (`en`), Cantonese (`yue`), Arabic (`ar`), German (`de`), French (`fr`), Spanish (`es`), Portuguese (`pt`), Indonesian (`id`), Italian (`it`), Korean (`ko`), Russian (`ru`), Thai (`th`), Vietnamese (`vi`), Japanese (`ja`), Turkish (`tr`), Hindi (`hi`), Malay (`ms`), Dutch (`nl`), Swedish (`sv`), Danish (`da`), Finnish (`fi`), Polish (`pl`), Czech (`cs`), Filipino (`fil`), Persian (`fa`), Greek (`el`), Hungarian (`hu`), Macedonian (`mk`), Romanian (`ro`).

Dialect/accent entries: Anhui, Dongbei, Fujian, Gansu, Guizhou, Hebei, Henan,
Hubei, Hunan, Jiangxi, Ningxia, Shandong, Shaanxi, Shanxi, Sichuan, Tianjin,
Yunnan, Zhejiang, Cantonese (Hong Kong), Cantonese (Guangdong), Wu, Minnan.
This is upstream's grouping; these are not 52 independent selectable languages.

### Nemotron 3.5 — 32 usable locales

[NVIDIA's source model card](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b)
defines 19 transcription-ready and 13 broad-coverage locales. The additional
eight adaptation-ready locales require fine-tuning: Greek, Lithuanian, Latvian,
Maltese, Slovenian, Hebrew, Thai and Norwegian Nynorsk. They are excluded from
ordinary transcription search results.

The [Core ML conversion card](https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML)
claims 100+ prompt IDs. That is not evidence of usable trained coverage and
conflicts with the original model's explicit tier definitions; the original
model's usable tiers take precedence.

Selectable locales (codes below are muesli's runtime preference IDs):

Arabic (`ar`), Bulgarian (`bg`), Chinese (`zh`), Croatian (`hr`), Czech (`cs`), Danish (`da`), Dutch (`nl`), English (`en`), English (UK) (`en-gb`), Estonian (`et`), Finnish (`fi`), French (`fr`), French (Canada) (`fr-ca`), German (`de`), Hindi (`hi`), Hungarian (`hu`), Italian (`it`), Japanese (`ja`), Korean (`ko`), Norwegian Bokmål (`nb`), Polish (`pl`), Portuguese (`pt`), Portuguese (Brazil) (`pt-br`), Romanian (`ro`), Russian (`ru`), Slovak (`sk`), Spanish (`es`), Spanish (Spain) (`es-es`), Swedish (`sv`), Turkish (`tr`), Ukrainian (`uk`), Vietnamese (`vi`).

The unqualified English, French, Portuguese and Spanish preferences correspond
to en-US, fr-FR, pt-PT and es-US respectively. The separate regional preferences
are en-GB, fr-CA, pt-BR and es-ES. Thus 32 locales represent 28 base languages.

### Cohere Transcribe — 14 languages

Source: [Cohere documentation](https://docs.cohere.com/docs/transcribe).
Choose the input language explicitly; the model does not provide explicit
automatic language detection.

English (`en`), French (`fr`), German (`de`), Spanish (`es`), Italian (`it`), Portuguese (`pt`), Dutch (`nl`), Polish (`pl`), Greek (`el`), Arabic (`ar`), Japanese (`ja`), Chinese (`zh`), Vietnamese (`vi`), Korean (`ko`).

### Bodhan Core — 25; Flex — 27

Sources: [Core](https://huggingface.co/bodhan-ai/indic-transcribe-core),
[Flex](https://huggingface.co/bodhan-ai/indic-transcribe-flex).
Pro and smaller INT8 variants have the same respective language coverage.
Core's set:

English (`en`), Hindi (`hi`), Tamil (`ta`), Telugu (`te`), Bengali (`bn`), Marathi (`mr`), Malayalam (`ml`), Kannada (`kn`), Assamese (`as`), Bodo (`brx`), Dogri (`doi`), Gujarati (`gu`), Kashmiri (`ks`), Konkani (`kok`), Maithili (`mai`), Manipuri (`mni`), Nepali (`ne`), Odia (`or`), Punjabi (`pa`), Sanskrit (`sa`), Santali (`sat`), Sindhi (`sd`), Urdu (`ur`), Bhojpuri (`bho`), Bhili (`bhb`).

Flex adds Chhattisgarhi (`hne`) and Haryanvi (`bgc`). Output script modes do
not add input languages. English is specifically Indian-accented in the cards.

### SenseVoice Small — five languages

[Upstream Small-specific release description](https://huggingface.co/FunAudioLLM/SenseVoiceSmall):
Chinese/Mandarin (`zh`), Cantonese (`yue`), English (`en`), Japanese (`ja`), Korean (`ko`).
The larger family's 50+ claim does not apply to Small.

### Gemma 4 E2B and E4B — 12 evaluated ASR languages

[Google technical report, Table 7](https://arxiv.org/html/2607.02770v2):
English (`en`), Korean (`ko`), Japanese (`ja`), German (`de`), French (`fr`),
Hindi (`hi`), Spanish (`es`), Italian (`it`), Portuguese/Brazil (`pt-BR`),
Russian (`ru`), Arabic (`ar`), Chinese/Mandarin (`zh`).

These are published evaluations of the original models, not an exhaustive
support declaration or a benchmark of the LiteRT conversions. No authoritative
complete ASR language list was found. In particular, Turkish remains unconfirmed;
it must not be inferred from the 140+ text languages or from translation targets.

### Apple Speech — runtime-specific coverage

[Apple's supportedLocales API](https://developer.apple.com/documentation/speech/speechtranscriber/supportedlocales)
is authoritative for the device and OS version. It includes downloadable locales,
not just installed assets, and is empty on unsupported devices. There is no
fixed cross-version list to hard-code. Do not substitute macOS keyboard dictation
or DictationTranscriber language lists: they use different models.

## Search performance and presentation

An immutable, in-memory index caches model coverage, normalized names, language
codes, dialects and localized/native aliases. Repeated languages are indexed once
per catalog snapshot. Filtering and matched-language labels are produced in one
pass when the query changes. SwiftUI renders stored results; unrelated download
progress or settings updates do not repeat searches or locale lookups. Apple
coverage and locale changes rebuild the snapshot and refresh the current query.
The small catalog uses immediate matching, with no debounce delay or asynchronous
results that could overwrite a newer query. Matching language names appear with
a globe at the top of each result card, before the model title.
