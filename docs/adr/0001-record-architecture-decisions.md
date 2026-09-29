# 0001. ADR로 설계 결정을 기록한다

- 상태: Accepted
- 날짜: 2026-09-29

## 맥락
KeyHue는 macOS 입력 시스템(TIS), 권한(TCC), 윈도우 레벨 등 문서화가 부족하고 OS 버전에 따라 동작이 달라지는 영역에 의존한다. "왜 이 API를 썼는지", "왜 이 기본값인지"를 코드만으로는 알기 어렵다.

## 결정
`docs/adr/`에 번호를 붙인 Markdown 파일로 설계 결정을 남긴다(Michael Nygard 형식).

- 파일명: `NNNN-kebab-case-title.md`
- 섹션: 상태 / 날짜 / 맥락 / 결정 / 결과 / (검토한 대안)
- 결정을 바꿀 때는 기존 ADR을 수정하지 않고 새 ADR을 추가한 뒤 기존 ADR 상태를 `Superseded by NNNN`으로 바꾼다.
- 목록은 [README.md](README.md)에 유지한다.

## 결과
- 제품 명세([docs/SPEC.md](../SPEC.md))와 구현 결정(ADR)이 분리된다.
- 결정의 근거와 트레이드오프가 남아, 이후 OS 업데이트로 동작이 바뀌었을 때 재검토 지점을 찾기 쉽다.
