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
