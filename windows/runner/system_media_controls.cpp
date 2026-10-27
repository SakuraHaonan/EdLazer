#include "system_media_controls.h"
#include <flutter/standard_method_codec.h>
#include <shlwapi.h>
#include <shcore.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Media.Playback.h>
#include <winrt/Windows.Storage.Streams.h>
#include <algorithm>
#include <mutex>
#include <string>

namespace {
constexpr UINT kMediaEvent = WM_APP + 0x4c;
struct MediaEvent {
  std::string method;
  int64_t position = 0;
  uint64_t epoch = 0;
};
struct EventTarget {
  std::mutex mutex;
  HWND window = nullptr;
  uint64_t epoch = 0;
};
uint64_t CurrentEpoch(const std::shared_ptr<EventTarget>& target) {
  const std::lock_guard<std::mutex> lock(target->mutex);
  return target->epoch;
}
void Post(const std::weak_ptr<EventTarget>& weak, uint64_t epoch,
          MediaEvent event) {
  if (const auto target = weak.lock()) {
    const std::lock_guard<std::mutex> lock(target->mutex);
    if (!target->window || target->epoch != epoch) return;
    event.epoch = epoch;
    auto message = std::make_unique<MediaEvent>(std::move(event));
    if (::PostMessage(target->window, kMediaEvent, 0,
                      reinterpret_cast<LPARAM>(message.get()))) message.release();
  }
}
const flutter::EncodableValue* Value(const flutter::EncodableMap& map, const char* key) {
  const auto found = map.find(flutter::EncodableValue(key));
  return found == map.end() ? nullptr : &found->second;
}
std::string String(const flutter::EncodableMap& map, const char* key) {
  const auto value = Value(map, key);
  const auto text = value ? std::get_if<std::string>(value) : nullptr;
  return text ? *text : "";
}
bool Boolean(const flutter::EncodableMap& map, const char* key) {
  const auto value = Value(map, key);
  const auto boolean = value ? std::get_if<bool>(value) : nullptr;
  return boolean && *boolean;
}
int64_t Integer(const flutter::EncodableMap& map, const char* key) {
  const auto value = Value(map, key);
  if (!value) return 0;
  if (const auto number = std::get_if<int64_t>(value)) return *number;
  if (const auto number = std::get_if<int32_t>(value)) return *number;
  return 0;
}
}

struct SystemMediaControls::Impl {
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel;
  std::shared_ptr<EventTarget> target = std::make_shared<EventTarget>();
  winrt::Windows::Media::Playback::MediaPlayer player{nullptr};
  winrt::Windows::Media::SystemMediaTransportControls controls{nullptr};
  winrt::Windows::Media::SystemMediaTransportControls::ButtonPressed_revoker buttons;
  winrt::Windows::Media::SystemMediaTransportControls::PlaybackPositionChangeRequested_revoker seeks;
  explicit Impl(flutter::BinaryMessenger* messenger, HWND window) {
    target->window = window;
    channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "org.haonan.edlazer/system_media", &flutter::StandardMethodCodec::GetInstance());
    channel->SetMethodCallHandler([this](const auto& call, auto result) {
      try {
        if (call.method_name() == "initialize") Initialize();
        else if (call.method_name() == "deinitialize") Deinitialize();
        else if (call.method_name() == "clear") {
          if (controls) controls.IsEnabled(false);
        } else if (const auto args = std::get_if<flutter::EncodableMap>(call.arguments())) {
          // Metadata/state arriving after independent disable must be ignored;
          // only the explicit initialize method may recreate native controls.
          if (!controls) {
            result->Success();
            return;
          }
          if (call.method_name() == "metadata") Metadata(*args);
          else if (call.method_name() == "state") State(*args);
          else { result->NotImplemented(); return; }
        } else { result->Error("arguments", "Expected media state"); return; }
        result->Success();
      } catch (const winrt::hresult_error& error) {
        result->Error("system_media", winrt::to_string(error.message()));
      }
    });
  }
  ~Impl() {
    const HWND window = target->window;
    Deinitialize();
    {
      const std::lock_guard<std::mutex> lock(target->mutex);
      target->window = nullptr;
      ++target->epoch;
    }
    channel->SetMethodCallHandler(nullptr);
    MSG message;
    while (::PeekMessage(&message, window, kMediaEvent, kMediaEvent, PM_REMOVE)) {
      delete reinterpret_cast<MediaEvent*>(message.lParam);
    }
  }
  void Deinitialize() {
    {
      const std::lock_guard<std::mutex> lock(target->mutex);
      ++target->epoch;
    }
    buttons.revoke();
    seeks.revoke();
    try {
      if (controls) {
        controls.IsEnabled(false);
        controls.DisplayUpdater().ClearAll();
        controls.DisplayUpdater().Update();
      }
      if (player) player.Close();
    } catch (...) {}
    controls = nullptr;
    player = nullptr;
  }
  void Initialize() {
    if (controls) return;
    const auto epoch = [&] {
      const std::lock_guard<std::mutex> lock(target->mutex);
      return target->epoch;
    }();
    player = winrt::Windows::Media::Playback::MediaPlayer();
    player.CommandManager().IsEnabled(false);
    controls = player.SystemMediaTransportControls();
    controls.IsEnabled(false);
    controls.IsPlayEnabled(true); controls.IsPauseEnabled(true);
    controls.IsStopEnabled(true);
    controls.IsFastForwardEnabled(false); controls.IsRewindEnabled(false);
    const std::weak_ptr<EventTarget> weak = target;
    buttons = controls.ButtonPressed(winrt::auto_revoke, [weak, epoch](const auto&, const auto& args) {
      using Button = winrt::Windows::Media::SystemMediaTransportControlsButton;
      switch (args.Button()) {
        case Button::Play: Post(weak, epoch, {"play"}); break;
        case Button::Pause: Post(weak, epoch, {"pause"}); break;
        case Button::Next: Post(weak, epoch, {"next"}); break;
        case Button::Previous: Post(weak, epoch, {"previous"}); break;
        case Button::Stop: Post(weak, epoch, {"stop"}); break;
        default: break;
      }
    });
    seeks = controls.PlaybackPositionChangeRequested(winrt::auto_revoke,
      [weak, epoch](const auto&, const auto& args) {
        Post(weak, epoch, {"seek", args.RequestedPlaybackPosition().count() / 10000});
      });
  }
  void Metadata(const flutter::EncodableMap& args) {
    auto display = controls.DisplayUpdater();
    display.ClearAll();
    display.Type(winrt::Windows::Media::MediaPlaybackType::Music);
    display.AppMediaId(L"org.haonan.edlazer");
    display.MusicProperties().Title(winrt::to_hstring(String(args, "title")));
    display.MusicProperties().Artist(winrt::to_hstring(String(args, "artist")));
    display.MusicProperties().AlbumTitle(winrt::to_hstring(String(args, "album")));
    const auto path = String(args, "artPath");
    if (!path.empty()) {
      // File streams avoid network requests without CDN headers and perform no
      // blocking WinRT async waits on the STA/UI thread.
      winrt::com_ptr<IStream> stream;
      if (SUCCEEDED(::SHCreateStreamOnFileEx(winrt::to_hstring(path).c_str(),
          STGM_READ | STGM_SHARE_DENY_WRITE, 0, FALSE, nullptr, stream.put()))) {
        winrt::Windows::Storage::Streams::IRandomAccessStream random{nullptr};
        if (SUCCEEDED(::CreateRandomAccessStreamOverStream(stream.get(), BSOS_DEFAULT,
            winrt::guid_of<winrt::Windows::Storage::Streams::IRandomAccessStream>(),
            winrt::put_abi(random)))) {
          display.Thumbnail(winrt::Windows::Storage::Streams::RandomAccessStreamReference::CreateFromStream(random));
        }
      }
    }
    display.Update();
  }
  void State(const flutter::EncodableMap& args) {
    using namespace winrt::Windows::Media;
    controls.IsEnabled(Boolean(args, "enabled"));
    controls.IsNextEnabled(Boolean(args, "next"));
    controls.IsPreviousEnabled(Boolean(args, "previous"));
    controls.PlaybackStatus(Boolean(args, "playing") ? MediaPlaybackStatus::Playing : MediaPlaybackStatus::Paused);
    const auto duration = std::max<int64_t>(0, Integer(args, "durationMs"));
    const auto position = std::clamp<int64_t>(Integer(args, "positionMs"), 0, duration);
    SystemMediaTransportControlsTimelineProperties timeline;
    timeline.StartTime(winrt::Windows::Foundation::TimeSpan{0});
    timeline.EndTime(winrt::Windows::Foundation::TimeSpan{duration * 10000});
    timeline.MinSeekTime(winrt::Windows::Foundation::TimeSpan{0});
    timeline.MaxSeekTime(winrt::Windows::Foundation::TimeSpan{duration * 10000});
    timeline.Position(winrt::Windows::Foundation::TimeSpan{position * 10000});
    controls.UpdateTimelineProperties(timeline);
  }
};

SystemMediaControls::SystemMediaControls(flutter::BinaryMessenger* messenger, HWND window)
    : impl_(std::make_unique<Impl>(messenger, window)) {}
SystemMediaControls::~SystemMediaControls() = default;
bool SystemMediaControls::HandleWindowMessage(UINT message, LPARAM parameter) {
  if (message != kMediaEvent) return false;
  const std::unique_ptr<MediaEvent> event(reinterpret_cast<MediaEvent*>(parameter));
  if (CurrentEpoch(impl_->target) != event->epoch) return true;
  impl_->channel->InvokeMethod(event->method, event->method == "seek"
    ? std::make_unique<flutter::EncodableValue>(event->position) : nullptr);
  return true;
}
