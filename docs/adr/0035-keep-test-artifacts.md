# 0035. 테스트 결과(로그·캡처)는 `.artifacts/<종류>/<시각>/`에 남기고, 마지막 실행은 링크로 연다

- 상태: Accepted
- 날짜: 2026-09-30

## 맥락
"테스트할 때 캡처 같은 것을 특정 폴더에 남겨서 사용자가 확인할 수 있게 하고, gitignore 처리하면 가독성이 올라가고 이전 기록도 볼 수 있다. 마지막 테스트는 심볼릭 링크로"라는 제안이 있었다.

그때의 상태는 이랬다.
- `scripts/verify.sh`만 `.artifacts/verify/<시각>/`에 로그를 남기고, `TestResults`가 그 마지막 실행을 가리켰다. 오래된 기록은 지우지 않아 39회분이 쌓여 있었다.
- `Tests/perf/*.sh`는 KeyHue 로그와 결과를 임시 폴더에 두었다가 끝나면 모두 지웠다. 실패해도 화면에 출력된 것 말고는 남지 않았다.
- `scripts/screenshots.sh --check`는 렌더링 결과와 차이 이미지를 `build/work/site/screens-check/`에 두고, 다음 실행 때 지웠다.
- 캡처로 확인한 것(ADR 0034)은 저장소 밖 임시 폴더에만 있었다.

## 결정
- **모든 테스트 결과를 `.artifacts/<종류>/<시각>/`에 남긴다**(이미 `.gitignore`에 있음).
  - `verify`: 단계별 로그
  - `screenshots`: 렌더링 결과와 차이 이미지
  - `perf/<테스트 이름>`: 화면 출력(`summary.log`), KeyHue 로그, 캡처
- **링크로 마지막 실행을 연다.**
  - `<종류>/latest`: 그 종류의 마지막 실행
  - `.artifacts/latest`: 종류와 상관없이 마지막 실행
  - 저장소 루트의 `TestResults`: `.artifacts/latest`를 가리킨다. 이전에는 `verify`의 마지막 실행만 가리켰다.
- **종류마다 최근 20회만 남긴다**(`ARTIFACTS_KEEP`). 폴더 이름(시각) 순으로 오래된 것을 지운다. 같은 초에 다시 실행하면 `-2`를 붙여 덮어쓰지 않는다.
- 공통 부분은 `scripts/artifacts.sh`(`artifacts_dir`)에 둔다. 새 테스트 스크립트는 이것을 source해서 폴더를 받는다.
- 사용자 설정 백업(`app-switch-latency.sh`의 `defaults.plist`)과 빌드한 측정용 앱은 결과가 아니므로 계속 임시 폴더에 두고 지운다.
- 캡처는 측정용 앱 창 영역만 찍는다. 다른 앱 화면이 결과 폴더에 남지 않게 하기 위해서다.
- CI는 지금처럼 실패할 때 `.artifacts/verify`를 올린다.

## 결과
- 스크립트 테스트(`Tests/scripts/test_artifacts.sh`, bash 3.2에서도 확인)
  - 실행마다 시각 폴더를 만든다.
  - 종류별 `latest`는 그 종류의 마지막 실행을, 전체 `latest`와 `TestResults`는 종류와 상관없이 마지막 실행을 가리킨다.
  - 같은 초에 두 번 실행해도 덮어쓰지 않는다.
  - 최근 N회만 남기고, 다른 종류의 기록은 건드리지 않는다.
- 새 로컬 점검 `Tests/perf/input-indicator.sh`가 캡처를 결과 폴더에 남긴다(ADR 0034).
- 적용 후 첫 `verify.sh` 실행에서 쌓여 있던 39회분이 최근 20회로 정리됐다.
