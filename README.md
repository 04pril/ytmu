# ytmu — 내부 WireGuard + 재생 위젯 앱 열기 패치

NightFox의 YouTube Music 9.44.2(PIP 미포함) 배포판을 기준으로, **내부 프록시를 유지하면서 잠금화면·다이나믹 아일랜드의 재생 위젯을 눌러도 앱이 열리지 않는 문제를 보완**합니다.

**2026-11-10: 사용자가 실제 아이폰에서 v0.1을 테스트해 증상이 해결됐다고 확인했습니다.**
호스트 모의 테스트 19개도 통과했습니다. 다른 기기·서명 조합까지 모두 검증한 것은 아닙니다.

- [릴리즈: IPA · 추가 주입용 dylib · 전체 소스](https://github.com/04pril/ytmu/releases/latest)
- [상세 설치·진단·구현 문서](docs/NowPlayingLaunchFix.md)
- [앱 내부 WireGuard / HTTP · HTTPS · SOCKS5 설명](docs/WireGuard.md)

## 어떤 문제인가요?

음악은 재생되고 잠금화면과 다이나믹 아일랜드에도 현재 재생 정보가 뜨지만, 커버·제목이나 다이나믹 아일랜드를 짧게 눌렀을 때 YouTube Music이 열리지 않는 증상입니다. 홈 화면 위젯 확장과는 별개의 기능이므로 App Group 설정 문제와 바로 동일시하지 않습니다.

기준 IPA의 번들 ID는 `com.google.ios.youtubemusic`, 앱 버전은 `9.44.2`입니다. 이 패치는 번들 ID와 앱 표시 이름을 변경하지 않습니다.

## 원인과 해결 방향

**현재 관찰 결과는 Now Playing의 앱 연결 대상 문제와 부합합니다.** 실제 설치 ID를 대상으로 다시 연결하는 패치로 증상이 해결됐습니다. 다만 시스템 로그로 최초의 잘못된 연결 값이나 내부 실패 경로를 확인한 것은 아니므로, 정확한 근본 원인은 추정으로 구분합니다.

| 항목 | 확인 여부 | 대응 |
| --- | --- | --- |
| 앱 번들 ID 변경 | 기준 IPA와 설치 시 원래 ID를 유지했다고 확인. 이것만으로는 증상을 설명할 수 없음 | ID 변경을 전제로 수정하지 않음 |
| 서명 App ID와 설치 번들 ID의 불일치 | 실제 설치본의 서명 값을 확인하기 전에는 미확인. 이번 해결 사례에서 원인으로 확정되지 않음 | 진단에서 `application-identifier`를 읽어 비교. 불일치하면 맞는 프로파일로 재서명 |
| Now Playing 클라이언트의 앱 연결 대상 | 연결 대상을 다시 지정한 패치 적용 후 실기기 증상 해결 확인. 내부 원인에 대한 추론 | 실제 설치 ID를 앱 연결 대상으로 명시 |
| 기기·서명별 API 권한 또는 시스템 차이 | 모든 조합을 검증하지 않음 | API 사용 가능 여부·요청 횟수와 실제 탭 결과를 함께 확인 |

Apple의 서명 체계에서 `application-identifier`는 App ID Prefix와 번들 ID로 구성됩니다. 앱 이름이나 Info.plist의 번들 ID만 확인한 것으로 서명 값까지 일치한다고 확정할 수는 없습니다. 불일치가 발견되면 올바른 프로파일로 다시 서명해야 하고, 이 dylib가 서명 권한을 바꿀 수는 없습니다. [Apple TN2415](https://developer.apple.com/library/archive/technotes/tn2415/_index.html)

### 이번 패치의 해결 방식

`MPNowPlayingInfoCenter` 생성·재생 정보 전달 후 다음 요청을 보냅니다.

```objc
MRMediaRemoteSetParentApplication(
    MRMediaRemoteGetLocalOrigin(),
    actualInstalledBundleIdentifier
);
```

실제 설치 ID는 디스크의 Info.plist에서 읽어 로그인 호환성을 위한 NSBundle ID 위장에 의존하지 않습니다. 원래 재생 메타데이터는 수정하지 않고 전달합니다.

이는 WebKit에도 사용례가 있는 MediaRemote의 앱 연결 API를 활용한 우회입니다. **공개 iOS API가 아니며**, 기기·서명 권한에 따라 요청이 무시될 수 있습니다. 함수 반환형이 void이므로 요청 횟수만으로 iOS의 승인이나 해결을 판단하지 않습니다. [WebKit 사용례](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/audio/cocoa/MediaSessionManagerCocoa.mm), [함수 선언](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/cocoa/MediaRemoteSoftLink.h)

## 다운로드와 설치

[Releases](https://github.com/04pril/ytmu/releases/latest)에서 필요한 파일을 받습니다.

| 파일 | 사용법 |
| --- | --- |
| `YTMUltimate_9.44.2_WireGuard_NowPlaying_v0.1.ipa` | 기존 내부 WireGuard를 포함한 IPA. 본인 인증서로 앱 전체를 재서명해서 설치 |
| `YTMU_NowPlayingLaunch_v0.1.dylib` | 원본 NightFox 9.44.2 IPA에 **추가 주입**한 뒤 앱 전체를 재서명 |
| `YTMU_WireGuard_NowPlaying_v0.1_Source.zip` | 프록시와 패치를 포함한 전체 소스. 아래 빌드 방법 참고 |
| `SHA256SUMS.txt` | 릴리즈 파일 무결성 확인용 |

완성 IPA를 쓰는 경우 dylib를 다시 주입하지 않습니다. 기존 `YTMusicUltimate.dylib`를 이 작은 dylib로 교체하면 프록시 등 기존 기능을 잃게 되므로 **추가 주입**으로 사용합니다. 기존 내부 WireGuard가 있는 앱에 예전 `YTMAppProxy`를 중복 주입하지 않습니다.

이번 IPA는 원래 3개 dylib를 바이트 단위로 보존하고, 실행파일에 새 dylib 로드 항목을 추가했습니다. 번들 ID·Info.plist는 유지합니다. 기기에 설치하려면 본인 인증서로 전체 재서명이 필요합니다. 개인 WireGuard 설정, 인증서, 개인키는 릴리즈에 포함하지 않습니다.

### 설치 후 확인

1. 앱을 완전히 종료했다가 다시 엽니다.
2. 본인의 내부 프록시 설정으로 곡을 재생합니다.
3. 화면을 잠그고 재생 위젯의 커버나 제목을 누릅니다. 다이나믹 아일랜드도 짧게 눌러 확인합니다.
4. 안 열리면 **설정 → YTMusicUltimate → 앱 내부 WireGuard → 앱 열기 진단 → 진단 복사**를 확인합니다.
5. 서명 App ID가 다르면 프로파일·서명 설정을 확인합니다. 진단에서 읽기 불가로 나오면 일치 여부도 미확인입니다.

진단 창에서 패치를 끄고 앱을 재시작할 수 있습니다. 원본 IPA로 돌아가면 패치를 완전히 제거할 수 있습니다. 공개 이슈에 진단을 올릴 때는 자신의 App ID 등 식별 정보를 가려도 됩니다. 재서명으로 Keychain 접근 그룹이 바뀌었다면 WireGuard `.conf`를 다시 가져와야 할 수 있습니다.

v0.1 진단 화면의 ‘실기기 검증 필요’ 문구는 빌드 당시 문구입니다. 그 바이너리에 대해 위 날짜에 사용자의 해결 확인을 받았으며, 기기별 확인은 계속 필요합니다.

## 다른 사람도 빌드하기

### 추가 주입용 dylib만 빌드 (Mac + Xcode)

```sh
git clone https://github.com/04pril/ytmu.git
cd ytmu
python3 tools/build_nowplaying.py
```

결과: `output/YTMU_NowPlayingLaunch_v0.1.dylib`

본인이 준비한 원본 NightFox 9.44.2 IPA에 추가하여 패키징하려면:

```sh
python3 tools/package_nowplaying.py /path/to/YTMUltimate_9.44_No_PIP.ipa
```

결과 IPA도 기기 설치 전 본인의 인증서로 전체 재서명이 필요합니다.

### 전체 YTMU 빌드 (내부 프록시 포함)

Mac + Xcode + Theos 및 `WireGuard/go.mod`에 맞는 Go 도구 체인이 필요합니다.

```sh
WireGuard/build-ios.sh
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless SIDELOADING=1 WIREGUARD=1
```

`WIREGUARD=1`을 지정해야 내부 프록시가 포함됩니다. 이 전체 빌드에는 앱 열기 패치도 포함되므로 독립 dylib를 다시 주입하지 않습니다. 자세한 프록시 빌드·시험은 [WireGuard 문서](docs/WireGuard.md)를 참고하세요.

## 검증 범위

```sh
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wno-deprecated-declarations \
  tests/nowplaying/harness.m -framework Foundation -o /tmp/ytmu-nowplaying-check
/tmp/ytmu-nowplaying-check
```

19개 검사: 원래 메타데이터 전달, 앱 연결 대상, 켜기·끄기, API 없음, 원점 없음, 예외 격리, 중복 훅 방지, 서명 진단 분류 등입니다. 실제 Objective-C 런타임과 Foundation에서 **모의 미디어 API**를 사용합니다. 이 자동 테스트 자체가 iOS 앱 열기 성공을 증명하지는 않습니다.

별도로 **2026-11-10 사용자 실기기 테스트에서 증상 해결이 확인**되었습니다. 다른 서명·기기 조합에서의 결과도 이슈로 공유할 수 있습니다.

## 출처와 라이선스

- 기반: [kes158/YTMusicUltimate](https://github.com/kes158/YTMusicUltimate), MYmain [`8ca2d6f8684d87ddd90c32ee96797588b57e0c41`](https://github.com/kes158/YTMusicUltimate/commit/8ca2d6f8684d87ddd90c32ee96797588b57e0c41).
- 상위 프로젝트: [dayanch96/YTMusicUltimate](https://github.com/dayanch96/YTMusicUltimate).
- 기반 프로젝트의 README는 [UpstreamREADME.md](docs/UpstreamREADME.md)에 보존했습니다.
- 프로젝트 소스: [GPL-3.0](LICENSE). 기존 저작권·라이선스를 유지합니다.
- WireGuard 구성 요소: [서드파티 라이선스](WireGuard/THIRD_PARTY_LICENSES.txt).
- Google/YouTube 공식 프로젝트가 아닙니다.
