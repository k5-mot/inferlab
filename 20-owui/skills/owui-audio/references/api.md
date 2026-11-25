# owui-audio API reference

Open WebUI v0.13.4のOpenAPI Schemaから`scripts/owui-skills/generate_api_reference.py`で生成した。手で編集しない。

`*`は必須field。pathの`{id}`などは実際の値へ置き換える。

### `GET /api/v1/audio/config`

Get Audio Config


### `POST /api/v1/audio/config/update`

Update Audio Config

- body (application/json): `realtime`: RealtimeConfigForm, `stt`*: STTConfigForm, `tts`*: TTSConfigForm

### `GET /api/v1/audio/models`

Get Models


### `POST /api/v1/audio/speech`

Speech


### `POST /api/v1/audio/transcriptions`

Transcription

- body (multipart/form-data): `file`*: string, `language`: string

### `GET /api/v1/audio/voices`

Get Voices
