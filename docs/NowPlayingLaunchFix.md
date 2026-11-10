# YTMU 잠금화면·다이나믹 아일랜드 앱 열기 시험 패치 v0.1

대상: NightFox 소스 목록의 YouTubeMusic(PIP 미포함), 앱 9.44.2, 번들 ID
`com.google.ios.youtubemusic`. 기반 소스는 `kes158/YTMusicUltimate`의 MYmain,
커밋 `8ca2d6f8684d87ddd90c32ee96797588b57e0c41`입니다.

## 현재 확인한 사실

- 배포 IPA의 실제 번들 ID도 `com.google.ios.youtubemusic`입니다.
- 기존 `YTMusicUltimate.dylib`에는 앱 내부 WireGuard가 포함되어 있습니다.
- 앱 실행파일에 `MPNowPlayingInfoCenter`, `defaultCenter`, `setNowPlayingInfo:`가 있습니다.
- 사용자와 친구에게 재생 위젯을 눌러도 앱이 열리지 않는 증상이 있습니다.
- **2026-11-10: 사용자가 실제 아이폰에서 이 패치를 테스트해 증상 해결을 확인했습니다.**
- iOS 내부 로그로 근본 원인까지 확정한 것은 아니며, 다른 서명·기기 조합에서의 동작은 별도 확인이 필요합니다.

앱의 번들 ID를 바꾸지 않았다는 사실만으로 실제 서명의 `application-identifier` 값까지
일치한다고 확인할 수는 없습니다. 반대로 아직 서명 불일치가 발견된 것도 아닙니다.
서명이 맞더라도 iOS의 재생 클라이언트 연결이나 시스템 상태 문제일 수 있습니다.

## 적용

방법 A: `YTMUltimate_9.44.2_WireGuard_NowPlaying_v0.1.ipa`를 본인이 쓰는 인증서로
**앱 전체를 재서명**해 설치합니다. 기존과 같은 번들 ID와 표시 이름을 사용합니다.
이 파일은 기기용 인증서로 서명되어 있지 않습니다.

방법 B: 원본 NightFox 9.44.2 IPA에 `YTMU_NowPlayingLaunch_v0.1.dylib`를
서명 도구의 dylib/라이브러리 주입 기능으로 **추가 주입**하고 앱 전체를 서명합니다.
파일을 단순히 복사하는 것만으로는 로드되지 않습니다.

- 두 방법 중 하나만 사용합니다.
- 원래 `YTMusicUltimate.dylib`를 이 작은 dylib로 교체하면 안 됩니다.
- 기존 WireGuard가 있는 앱에 예전 `YTMAppProxy`를 중복 주입하지 않습니다.
- 이번 패키지의 원래 3개 dylib는 바이트 단위로 보존했습니다. 프록시 엔진을 다시 구현하거나
  교체하지 않고 원래 배포판 것을 유지합니다.
- 개인 WireGuard 설정과 인증서는 포함하지 않았습니다. 재서명으로 Keychain 접근 그룹이 달라지면
  본인의 `.conf`를 앱에서 다시 가져와야 할 수 있습니다.

## 아이폰 확인

1. 설치 후 앱을 완전히 종료했다가 엽니다.
2. 평소처럼 내부 프록시로 곡을 재생합니다.
3. 잠금화면 재생 위젯의 커버/제목을 누릅니다. 다이나믹 아일랜드의 짧은 탭도 확인합니다.
   길게 누르기는 재생 컨트롤을 펼치는 동작이므로 구분합니다.
4. 안 열리면 앱 설정 → YTMusicUltimate → 앱 내부 WireGuard → 우측 **앱 열기 진단** → **진단 복사**.
5. 진단에는 실제 번들 ID, 서명 App ID(읽을 수 있는 경우), 재생 정보 전달 횟수와
   앱 연결 요청 횟수만 들어갑니다. WireGuard 키·서명 인증서·음악 URL은 읽지 않습니다.

연결 요청 횟수가 늘어도 iOS가 그 요청을 승인했다거나 실제 탭 동작이 성공했다는 뜻은 아닙니다.
서명 App ID가 다르면 올바른 앱 ID를 허용하는 프로파일로 다시 서명해야 합니다.
원래 ID를 유지하려면 그 ID를 허용하는 프로파일이 필요하고, dylib가 서명 권한을 바꿀 수는 없습니다.

문제가 생기면 진단 창에서 **패치 끄기** 후 앱을 재시작하거나 원본 IPA로 돌아갑니다.

## 구현과 한계

`Source/NowPlaying/YTMUNowPlayingFix.m`는 실제 디스크의 Info.plist에서 설치 ID를 읽습니다.
`MPNowPlayingInfoCenter` 생성 및 재생 정보 전달 후 MediaRemote의
`MRMediaRemoteSetParentApplication(MRMediaRemoteGetLocalOrigin(), 실제_번들_ID)`를 요청합니다.
이는 재생 클라이언트의 앱 연결 대상을 명시하는 **실험적 우회**이며 공개 iOS API가 아닙니다.
API가 없거나 원점(origin)을 얻지 못하면 건너뛰고, Objective-C 예외가 발생하면 해당 실행에서 중단합니다.
void 반환 API이므로 승인 여부를 확인할 수 없습니다. 일반 앱의 권한에서 무시될 가능성도 있습니다.

메타데이터와 재생 명령은 원래 구현에 그대로 전달하며 번들 ID·로그인 코드·음악 전송 경로는
변경하지 않습니다. 자동으로 다른 앱을 띄우는 타이머나 URL 가로채기는 없습니다.

근거 자료:

- [Apple: CFBundleIdentifier](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleidentifier)
- [Apple TN2415: application-identifier와 프로비저닝 프로파일](https://developer.apple.com/library/archive/technotes/tn2415/_index.html)
- [WebKit: Now Playing parent application 설정·해제 사용례](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/audio/cocoa/MediaSessionManagerCocoa.mm)
- [WebKit: MediaRemote 함수 ABI](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/cocoa/MediaRemoteSoftLink.h)

## 재빌드

독립 추가 dylib (Mac + Xcode):

```sh
python3 tools/build_nowplaying.py
python3 tools/package_nowplaying.py /path/to/YTMUltimate_9.44_No_PIP.ipa
```

전체 YTMU 소스 빌드 (프록시 포함, Theos 필요):

```sh
WireGuard/build-ios.sh
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless SIDELOADING=1 WIREGUARD=1
```

기존 Makefile이 `Source` 아래 `.m` 파일을 수집하므로 전체 빌드에는 이 패치도 포함됩니다.
그때는 독립 dylib를 중복 주입하지 않습니다. 프록시 설명은 `docs/WireGuard.md`를 참고합니다.

호스트 검증:

```sh
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wno-deprecated-declarations \
  tests/nowplaying/harness.m -framework Foundation -o /tmp/ytmu-nowplaying-check
/tmp/ytmu-nowplaying-check
```

실제 Objective-C 런타임과 Foundation에서 모의 MPNowPlayingInfoCenter/MediaRemote를 사용합니다.
정확한 메타데이터 보존, 중복 설치 방지, 켜기/끄기, API 없음·예외, 진단 분류를 검증합니다.
**iOS 잠금화면·다이나믹 아일랜드·서명 권한·실제 앱 열기 성공을 검증하는 테스트는 아닙니다.**
