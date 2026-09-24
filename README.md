# PCM audio layer

`PCM` is a portable PCM audio output layer. The emulator code
only works with the TPCMAudio facade; the selection of the native API and queue management remain
in the backend.

## Composition

| Unit | Purpose |
| --- | --- |
| ` PCM.Audio` | Public facade: 'TPCMAudio', queue format and status. |
| `PCM.Audio.Backend` | The 'IPCMAudioBackend` contract and common record types. |
| `PCM.Audio.Factory` | Selects the backend for the target platform. |
| `PCM.Audio.Windows.MMSystem` | Windows WaveOut (`winmm`). |
| `PCM.Audio.Android.AudioTrack` | Android `AudioTrack`. |
| `PCM.Audio.Linux.Alsa` | ALSA. |
| `PCM.Audio.Apple.AudioQueue` | macOS/iOS Audio Queue. |
| `PCM.Audio.Null` | Silent backend for unsupported platforms and tests. |

## Usage

```pascal
uses PCM.Audio;

var AudioFormat: TPCMAudioFormat;
AudioFormat.SampleRate := 44100;
AudioFormat.Channels := 1;
AudioFormat.BlockFrames := 1024;
AudioFormat.BlockCount := 4;

var Audio := TPCMAudio.Create(AudioFormat);
try
  Audio.Submit(Samples, FrameCount);
  var State := Audio.QueueState;
  if Audio.Error <> '' then
  begin
// Pass Audio.Error to the log or the application status.
  end;
finally
  Audio.Free;
end;
```

`Samples` contains signed 16-bit PCM values (`SmallInt') in
interleaved order. `Count` is the number of **frames**, not the number of values: for
stereo format, the array must contain at least `Count * Channels'
of elements. The `Count` must be in the range from `0` to `BlockFrames'.

Create, use, and destroy TPCMAudio in a single thread. This is especially
important for backends, whose native resources and callbacks are linked to
the owner's stream.

## Queue and errors

`Submit` does not wait for playback: the backend copies the block to its own buffer and
returns control. If the device is full or unavailable, frames
are discarded, which is reflected in `DroppedSamples`.

'QueueState` returns a snapshot of the status:

| Field | Value |
| --- | --- |
| ` SubmittedSamples` | The accumulated number of frames received. |
| `DroppedSamples` | The accumulated number of dropped frames. |
| `Clears` | The number of cleanup calls; the counter is 32-bit. |
| `PlayedSamples` | Playback position, valid only for `PositionKnown = True'; can be reset after `Clear'. |
| `QueuedBlocks` | Estimation of the number of blocks awaiting output. |
| `DeviceOpen` | The device is successfully opened. |
| `PositionKnown` | The backend was able to determine the playback position. |

`Clear` immediately discards pending playback. The cumulative counters
of received and dropped frames are not reset to zero. Errors in the native backend are
available through the `Error` property; the application must periodically read it and
the queue status, rather than waiting for an exception for every device error.

## Choosing a platform

`PCM.Audio.Factory` selects the implementation at compile time:

| Condition | Backend |
| --- | --- |
| ` MSWINDOWS` | `PCM.Audio.Windows.MMSystem` |
| `ANDROID` | `PCM.Audio.Android.AudioTrack` |
| `LINUX` (not Android) | `PCM.Audio.Linux.Alsa` |
| `MACOS` or `IOS` | `PCM.Audio.Apple.AudioQueue` |
| Other platform | `PCM.Audio.Null` with the message that there is no implementation |

The definition of `PCM_AUDIO_NULL` forcibly selects `PCM.Audio.Null` on any
platform. This is convenient for headless builds and checking portable code without
opening the audio device.

In Delphi, add the facade itself, factory, backend, and the required platform
unit to the project. In 'NESFMX.dpr` this has already been done by conditional `uses` sections.

## Adding a backend

The new implementation must implement the 'IPCMAudioBackend` and honor the contract.:

1. Copy the input PCM data before returning from the `Submit`.
2. Do not block the calling stream while waiting for playback.
3. Limit the `blockCount` queue to blocks and account for overflow in
   `DroppedSamples`.
4. Cancel the pending playback in `Clear`.
5. Stop native callbacks before releasing buffers.
6. Report device failure via `Error` and `QueueState'.

After adding the unit, it is connected to the conditional sections of the PCM.Audio.Factory` and in
`uses` the project for the corresponding platform.


<details>
  <summary>ru</summary>

# PCM audio layer

`PCM` — переносимый слой вывода PCM-аудио. Код эмулятора работает
только с фасадом `TPCMAudio`; выбор нативного API и управление очередью остаются
в backend-ах.

## Состав

| Unit | Назначение |
| --- | --- |
| `PCM.Audio` | Публичный фасад: `TPCMAudio`, формат и состояние очереди. |
| `PCM.Audio.Backend` | Контракт `IPCMAudioBackend` и общие record-типы. |
| `PCM.Audio.Factory` | Выбирает backend по целевой платформе. |
| `PCM.Audio.Windows.MMSystem` | Windows WaveOut (`winmm`). |
| `PCM.Audio.Android.AudioTrack` | Android `AudioTrack`. |
| `PCM.Audio.Linux.Alsa` | ALSA. |
| `PCM.Audio.Apple.AudioQueue` | macOS/iOS Audio Queue. |
| `PCM.Audio.Null` | Беззвучный backend для неподдерживаемых платформ и тестов. |

## Использование

```pascal
uses PCM.Audio;

var AudioFormat: TPCMAudioFormat;
AudioFormat.SampleRate := 44100;
AudioFormat.Channels := 1;
AudioFormat.BlockFrames := 1024;
AudioFormat.BlockCount := 4;

var Audio := TPCMAudio.Create(AudioFormat);
try
  Audio.Submit(Samples, FrameCount);
  var State := Audio.QueueState;
  if Audio.Error <> '' then
  begin
    // Передайте Audio.Error в журнал или состояние приложения.
  end;
finally
  Audio.Free;
end;
```

`Samples` содержит знаковые 16-битные PCM-значения (`SmallInt`) в
interleaved-порядке. `Count` — число **кадров**, а не число значений: для
стерео-формата массив должен содержать как минимум `Count * Channels`
элементов. `Count` должен быть в диапазоне от `0` до `BlockFrames`.

Создавайте, используйте и уничтожайте `TPCMAudio` в одном потоке. Это особенно
важно для backend-ов, чьи нативные ресурсы и callbacks привязаны к потоку
владельца.

## Очередь и ошибки

`Submit` не ждёт воспроизведения: backend копирует блок в собственный буфер и
возвращает управление. При переполнении или недоступности устройства кадры
отбрасываются, что отражается в `DroppedSamples`.

`QueueState` возвращает снимок состояния:

| Поле | Значение |
| --- | --- |
| `SubmittedSamples` | Накопленное число принятых кадров. |
| `DroppedSamples` | Накопленное число отброшенных кадров. |
| `Clears` | Число вызовов очистки; счётчик 32-битный. |
| `PlayedSamples` | Позиция воспроизведения, действительна только при `PositionKnown = True`; может сбрасываться после `Clear`. |
| `QueuedBlocks` | Оценка числа блоков, ожидающих вывода. |
| `DeviceOpen` | Устройство успешно открыто. |
| `PositionKnown` | Backend смог определить позицию воспроизведения. |

`Clear` немедленно отбрасывает ожидающее воспроизведение. Накопительные счётчики
принятых и отброшенных кадров при этом не обнуляются. Ошибки нативного backend-а
доступны через свойство `Error`; приложение должно периодически читать его и
состояние очереди, а не ожидать исключение при каждой ошибке устройства.

## Выбор платформы

`PCM.Audio.Factory` выбирает реализацию во время компиляции:

| Условие | Backend |
| --- | --- |
| `MSWINDOWS` | `PCM.Audio.Windows.MMSystem` |
| `ANDROID` | `PCM.Audio.Android.AudioTrack` |
| `LINUX` (не Android) | `PCM.Audio.Linux.Alsa` |
| `MACOS` или `IOS` | `PCM.Audio.Apple.AudioQueue` |
| Иная платформа | `PCM.Audio.Null` с сообщением об отсутствии реализации |

Определение `PCM_AUDIO_NULL` принудительно выбирает `PCM.Audio.Null` на любой
платформе. Это удобно для headless-сборок и проверки переносимого кода без
открытия аудиоустройства.

В Delphi добавьте в проект сам фасад, factory, backend и нужный платформенный
unit. В `NESFMX.dpr` это уже сделано условными секциями `uses`.

## Добавление backend-а

Новая реализация должна реализовать `IPCMAudioBackend` и соблюдать контракт:

1. До возврата из `Submit` скопировать входные PCM-данные.
2. Не блокировать вызывающий поток в ожидании проигрывания.
3. Ограничить очередь `BlockCount` блоками и учитывать переполнение в
   `DroppedSamples`.
4. В `Clear` отменять ожидающее проигрывание.
5. Перед освобождением буферов остановить нативные callbacks.
6. Сообщать отказ устройства через `Error` и `QueueState`.

После добавления unit подключается в условные секции `PCM.Audio.Factory` и в
`uses` проекта для соответствующей платформы.
</details>
