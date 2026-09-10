# 아키텍처 — 확장 프로그램 (Chrome Extension)

유튜브 라이브 채팅 DOM에서 댓글을 실시간 수집해 서버 모델로 분류하고,
악성 라벨에 따라 화면에서 차단하는 Chrome Manifest V3 확장 프로그램.

관련 소스: `extension/manifest.json`, `content.js`, `background.js`,
`popup.html/js/css`, `options.html`

---

## 1. 구성

| 파일 | 역할 |
|---|---|
| `manifest.json` | MV3 매니페스트 — 권한, content script 매칭, service worker 등록 |
| `content.js` | 유튜브 페이지에 주입 — 채팅 DOM 관찰 · 수집 · 배지/차단 적용 · 학습 라벨링 UI |
| `background.js` | service worker — 서버 API 호출, 캐시 조회, 마스크/룰 후처리, 카운터 배지 |
| `popup.html/js` | 툴바 팝업 — 필터 on/off, 차단 기준/동작, 학습 모드, 재학습, 데이터 관리 |
| `options.html` | 옵션 페이지 — 서버 모드/주소, API Key, 차단 기준·동작, 배지 |
| `popup.css` | 팝업 스타일 |

### 권한 (`manifest.json`)

- `permissions`: `storage`, `scripting`, `activeTab`
- `host_permissions`: `https://www.youtube.com/*`, `http://localhost:8000/*`, `127.0.0.1:8000`, `:3000` (외부 서버 테스트)
- content script 매칭: `https://www.youtube.com/*` + `https://www.youtube.com/live_chat*`,
  `run_at: document_idle`, `all_frames: true` (라이브 채팅이 iframe이므로 필수)

---

## 2. content.js — 수집 → 분류 → 조치 파이프라인

### 2.1 DOM 관찰

- `MutationObserver`가 `document.body`의 childList/subtree를 감시.
- 새 `yt-live-chat-text-message-renderer` 추가 시 `#message` 엘리먼트를 추출
  (`shadowRoot` 대응).
- 진입 시 이미 렌더된 메시지도 초기 큐잉. 라이브 채팅이 뜰 때까지 최대 40회(0.5s 간격) 대기.

### 2.2 안정 키 & 디듀프

- `messageKey(el)`: DOM `id` → 없으면 `(author, timestamp, text)` 해시(`stableHash`).
- `enqueuedIds` / `processedIds` Set으로 중복 분류 방지.
- `processedIds`가 `PROCESSED_LIMIT`(4000) 초과 시 절반 GC.

### 2.3 큐 & 배치 flush (부하 제어)

| 파라미터 | 값 | 목적 |
|---|---|---|
| `BATCH_SIZE` | 20 | 기본 배치 크기 |
| dynamic batch | 큐 > 200 이면 100 | 버스트 빠른 소진 |
| `THROTTLE_MS` | 200 ms | 분류 호출 최소 간격 |
| `MAX_QUEUE` | 300 | 초과 시 오래된 항목 드롭 (`dropOverflow`) |
| bulk 모드 | DOM 120개↑ 추가 감지 시 1.5s 지연 | 대량 갱신 흡수 |

`scheduleFlush()` → `flushQueue()`가 배치를 잘라 `chrome.runtime.sendMessage({type:'classify'})`로
background에 전달, 라벨 배열을 받아 각 메시지에 적용. 실패 시 해당 배치는 `enqueuedIds`만 해제(재시도 가능).

### 2.4 조치 (`actOnSevere`)

- 임계치: `minSeverityToHide` (0 = 전부 표시 / 1 = 약간 악성↑ / 2 = 악성만).
- `action` 3종:
  - `hide` — `display:none`
  - `blur` — `filter: blur(6px)` + `opacity 0.5` (클릭은 허용)
  - `delete` — 유튜브 자체 메뉴의 삭제/숨김 클릭 시도, 실패 시 `hide`로 폴백
- 조치한 요소는 `.ylcf-acted` + `data-ylcf-action`으로 표시 → 설정 변경 시 되돌리기(`unapplyAllActions`).
- 조치 1건마다 `incCounter` 메시지 → 툴바 배지 카운트 증가.
- `applyBadge` — 옵션이 켜져 있으면 작성자명 옆에 `정상/약간 악성/악성` 색상 배지.

### 2.5 설정 실시간 반영 (`installAutoApply`)

`chrome.storage.onChanged`(local) 리스너:
- `minSeverityToHide` 0 → 기존 조치 즉시 해제
- `action` 변경 → 기존 조치 정리 후 신규 규칙 적용
- `enabled` false → 모든 조치/배지 제거 + 큐 비움 / true → 현재 보이는 메시지 재평가
- `trainingMode` 변경 → 기존 메시지에 클릭 핸들러 부착/해제

### 2.6 학습 데이터 수집 모드

- `trainingMode` on이면 각 채팅 메시지에 클릭 핸들러 부착(`cursor: pointer`).
- 클릭 → 모달(`showLabelingDialog`): 정상(0) / 약간 악성(1) / 악성(2) / 취소.
- 선택 시 `sendTrainingData` 메시지 → background → `POST /training-data`.
- 성공하면 해당 메시지에 2초간 파란 테두리 피드백. blur 상태 메시지는 클릭 시 2초간 원본 노출.

---

## 3. background.js — API 게이트웨이 & 후처리

service worker. `DEFAULT_SETTINGS`를 `chrome.storage.local`에서 로드.

### 3.1 `classify` 메시지 처리 (핵심 흐름)

```
originalTexts[]
  1) applyMaskToText   : masks[] 단어를 모델 입력 전에 제거 (정규식, 공백 정리)
  2) lookupCachedLabels: POST /training-data/lookup 으로 캐시 라벨 조회 (마스크된 텍스트 기준)
  3) 캐시 미스만        : POST /predict 로 서버 분류
  4) (학습 모드 한정)  : 미스 결과를 POST /training-data?temp=1 로 임시 캐시 저장
  5) applyRuleFloorToLabel: rules[] ({term,min}) — 특정 단어 포함 시 최소 심각도 강제(원문 기준)
  → { labels: ruled }
```

- **마스크(masks)**: 모델을 흔드는 불필요 토큰을 입력에서 제거.
- **룰(rules)**: 모델이 놓쳐도 특정 단어가 있으면 라벨 하한선을 올림 (`Math.max(modelLabel, floor)`).
- 캐시 우선 → `/predict` 호출량을 줄여 서버 부하·지연 감소.
- 운영 관점 왜곡 방지를 위해 temp 캐시 자동 저장은 학습 모드에서만 수행.

### 3.2 서버 모드

| 모드 | 대상 | 요청 |
|---|---|---|
| 로컬 (기본) | `serverUrl` (기본 `http://127.0.0.1:8000`) 또는 클라우드 API Gateway | `POST /predict` 배치 |
| 외부 (테스트) | `useExternalServer=true` | `POST /api/predict` 텍스트별 개별 요청, `probs` argmax로 라벨 재계산, 학습 기능 비활성 |

- 인증: `apiKey` 있으면 `X-API-Key` 헤더 부착 (서버 `ENFORCE_AUTH=true`일 때 필요, 로컬은 생략 가능).
- 실패 시 빈 라벨/`[1,0,0]` 폴백 — 채팅이 막히지 않도록.

### 3.3 기타 메시지

- `getSettings` — 팝업/콘텐츠에 설정 반환
- `incCounter` — 툴바 배지 텍스트 증가 (`#d9534f` 배경)
- `sendTrainingData` — `POST /training-data`

---

## 4. 팝업 (popup.js) — 운영 콘솔

- 필터 on/off (`enabled`), 차단 기준(`min`), 차단 동작(`act`), 배지(`badge`), 학습 모드(`trainingMode`) 토글.
- 학습 데이터 통계: `GET /training-data/stats` (정상/약간 악성/악성 분포).
- 데이터 관리: `GET /training-data/files`, 파일별 내용 보기, 파일/라인/전체 삭제, temp 삭제.
- **재학습**: `POST /model/retrain` → `GET /model/training-status`를 2초 간격 폴링하며 진행률 표시.
- **모델 재로드**: `POST /model/reload`.
- 룰/마스크 관리 UI: `{term,min}` 룰 추가·삭제, 마스크 단어 추가·삭제 (storage에 저장).
- 외부 서버 모드에서는 학습 관련 기능 자동 비활성화.

---

## 5. 옵션 페이지 (options.html)

- 서버 모드 선택(로컬/외부), 로컬 서버 주소, API Key(password).
- 차단 기준·동작, 배지 표시.
- "서버 점검" 버튼: 로컬은 `GET /health`, 외부는 `POST /api/predict` 테스트.

---

## 6. 저장 설정 스키마 (`chrome.storage.local`)

| 키 | 기본값 | 설명 |
|---|---|---|
| `enabled` | `true` | 필터 전체 on/off |
| `serverUrl` | `http://127.0.0.1:8000` | 로컬/클라우드 서버 |
| `apiKey` | `''` | `X-API-Key` |
| `useExternalServer` | `false` | 외부 테스트 서버 모드 |
| `minSeverityToHide` | `2` | 0=전부표시 / 1 / 2 |
| `action` | `'hide'` | `hide` / `blur` / `delete` |
| `showBadge` | `true` | 라벨 배지 |
| `trainingMode` | `false` | 클릭 라벨링 + temp 캐시 저장 |
| `rules` | `[]` | `[{term, min}]` 최소 심각도 강제 |
| `masks` | `[]` | 모델 입력 전 제거 단어 |

---

## 7. 확장 프로그램이 부담을 던 방식

- **배치 + throttle + 큐 상한**: 라이브 채팅 폭주 시에도 `/predict` 호출을 일정하게 유지.
- **캐시 우선 조회**: 반복 문구는 서버 추론 없이 처리.
- **마스크/룰 후처리**: 모델 재학습 없이 즉시 오탐/미탐을 보정.
- **폴백 설계**: 서버 오류·네트워크 실패 시 채팅을 막지 않고 통과.
