// === 변경된 background.js (발췌; 파일 전체 대체 권장) ===

// 새 기본 설정: rules, masks 추가
const DEFAULT_SETTINGS = {
  serverUrl: 'http://127.0.0.1:8000',
  apiKey: '',
  useExternalServer: false,    // true=외부서버(localhost:3000), false=로컬서버
  minSeverityToHide: 2,       // 2=악성 차단, 1=약간 악성 이상 차단
  action: 'hide',             // hide | blur | delete
  showBadge: true,
  trainingMode: false,        // true일 때만 임시 캐시 라벨도 저장
  rules: [],                  // [{ term: '시발', min: 2 }, { term: '이재명', min: 1 }]
  masks: []                   // ['시발', '욕설A', ...]
};

async function getSettings() {
  return new Promise(resolve => {
    chrome.storage.local.get(DEFAULT_SETTINGS, values => resolve(values));
  });
}

// 공백/구두점 경계까지 엄격할 필요가 있다면 정규식 개선 가능
function normalize(s){ return (s || '').toString(); }

function buildJsonHeaders(apiKey) {
  // API Key는 로컬 개발에서는 비어 있을 수 있다.
  // 값이 있을 때만 헤더에 실어 Phase 0 보안 옵션과 호환한다.
  const headers = { 'Content-Type': 'application/json' };
  if (apiKey) headers['X-API-Key'] = apiKey;
  return headers;
}

// --- 마스크 전처리: 모델 입력 전 불필요 단어 제거 ---
function applyMaskToText(text, masks) {
  if (!text || !Array.isArray(masks) || masks.length === 0) return text;
  let out = text;
  for (const m of masks) {
    if (!m) continue;
    // 단순 포함 제거(단어 경계가 필요하면 \b 사용 고려)
    const esc = m.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    out = out.replace(new RegExp(esc, 'g'), '');
  }
  return out.trim().replace(/\s{2,}/g, ' ');
}

// --- 룰 적용: 특정 단어 포함 시 최소 심각도 강제 ---
function applyRuleFloorToLabel(originalText, modelLabel, rules) {
  if (!originalText || !Array.isArray(rules) || rules.length === 0) return modelLabel ?? 0;
  const src = normalize(originalText);
  let floor = 0;
  for (const r of rules) {
    if (!r?.term) continue;
    const term = normalize(r.term);
    const min = Number(r.min ?? 0);
    if (!term) continue;
    if (src.includes(term)) {
      if (min > floor) floor = min;
    }
  }
  // 최소 0은 그대로(상향 없음). 그 외엔 floor를 하한선으로 적용.
  return Math.max(modelLabel ?? 0, floor);
}

async function classify(texts) {
  const { serverUrl, apiKey, useExternalServer } = await getSettings();
  
  if (useExternalServer) {
    // 외부 서버: 각 텍스트를 개별적으로 요청하고 결과를 배열로 변환
    const baseUrl = 'http://223.194.46.69:3000';
    const endpoint = '/api/predict';
    const url = `${baseUrl}${endpoint}`;
    
    console.log(`[EXTERNAL] Classifying ${texts.length} texts:`, texts);
    
    try {
      const promises = texts.map(text => 
        fetch(url, {
          method: 'POST',
          headers: buildJsonHeaders(apiKey),
          body: JSON.stringify({ texts: [text] })
        }).then(res => res.ok ? res.json() : null)
      );
      
      const results = await Promise.all(promises);
      
      // 외부 서버 응답 확인 및 라벨 변환
      // 외부 서버의 probs 순서를 확인하여 최대값의 인덱스를 라벨로 사용
      const labels = results.map(r => {
        // 외부 서버 응답: { ok: true, data: { label, probs, confidence } }
        if (!r || !r.data || !r.data.probs || r.data.probs.length !== 3) {
          console.warn('[EXTERNAL] Invalid response format:', r);
          return 0;
        }
        
        // probs에서 최대값의 인덱스 찾기 (외부 서버가 잘못된 label을 보낼 수 있으므로)
        const maxIdx = r.data.probs.indexOf(Math.max(...r.data.probs));
        
        console.log('[EXTERNAL] Single result:', { 
          serverLabel: r.data.label, 
          probs: r.data.probs, 
          calculatedLabel: maxIdx,
          confidence: r.data.confidence
        });
        
        return maxIdx;
      });
      
      const probs = results.map(r => r?.data?.probs ?? [1, 0, 0]);
      
      console.log('[EXTERNAL] Final results:', { 
        labels, 
        texts: texts.map((t, i) => ({ text: t, label: labels[i] })) 
      });
      
      return { labels, probs, label_names: { 0: '정상', 1: '약간 악성', 2: '악성' } };
    } catch (e) {
      console.warn('External server classification failed:', e);
      return { labels: texts.map(() => 0), probs: [], label_names: {} };
    }
  } else {
    // 로컬 서버: 기존 배치 처리 방식
    const url = `${serverUrl.replace(/\/$/, '')}/predict`;
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: buildJsonHeaders(apiKey),
        body: JSON.stringify({ texts })
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return await res.json();
    } catch (e) {
      console.warn('Classification request failed:', e);
      return { labels: [], probs: [], label_names: {} };
    }
  }
}

async function sendTrainingData(text, label, userId = 'anonymous', useTemp = false) {
  const { serverUrl, apiKey, useExternalServer } = await getSettings();
  // 외부 서버 사용 시 학습 데이터 전송 안 함
  if (useExternalServer) {
    console.log('External server mode: training data not sent');
    return { success: false, message: 'Training data not supported in external server mode' };
  }
  const url = `${serverUrl.replace(/\/$/, '')}/training-data${useTemp ? '?temp=1' : ''}`;
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: buildJsonHeaders(apiKey),
      body: JSON.stringify({ text, label, user_id: userId })
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return await res.json();
  } catch (e) {
    console.warn('Training data send failed:', e);
    return { success: false, message: e.message };
  }
}

async function lookupCachedLabels(texts) {
  const { serverUrl, apiKey, useExternalServer } = await getSettings();
  // 외부 서버 사용 시 캐시 조회 안 함
  if (useExternalServer) {
    return { labels: [] };
  }
  const url = `${serverUrl.replace(/\/$/, '')}/training-data/lookup`;
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: buildJsonHeaders(apiKey),
      body: JSON.stringify({ texts })
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return await res.json();
  } catch (e) {
    return { labels: [] };
  }
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type === 'classify') {
    (async () => {
      const settings = await getSettings();
      const rules = Array.isArray(settings.rules) ? settings.rules : [];
      const masks = Array.isArray(settings.masks) ? settings.masks : [];
      const trainingMode = !!settings.trainingMode;

      const originalTexts = message.texts || [];
      // 1) 모델 입력용 마스크 전처리
      const maskedTexts = originalTexts.map(t => applyMaskToText(t, masks));

      // 2) 캐시 조회(마스크된 텍스트 기준)
      const cached = await lookupCachedLabels(maskedTexts);

      // 3) 캐시 미스만 서버 분류
      const out = new Array(originalTexts.length).fill(null);
      const missIdxs = [];
      maskedTexts.forEach((t, i) => {
        const lbl = cached?.labels?.[i];
        if (lbl === 0 || lbl === 1 || lbl === 2) out[i] = lbl; else missIdxs.push(i);
      });
      if (missIdxs.length > 0) {
        const missTexts = missIdxs.map(i => maskedTexts[i]);
        const predicted = await classify(missTexts);
        missIdxs.forEach((i, k) => {
          out[i] = predicted.labels?.[k] ?? 0;
        });
        // 4) 분류 결과 temp 캐시 저장은 학습 모드에서만 수행한다.
        // 운영 관점에서는 이 write 트래픽이 기준선을 왜곡할 수 있으므로,
        // 재학습/수집을 하지 않을 때는 자동 저장을 끈다.
        if (trainingMode) {
          missIdxs.forEach((i) => {
            const lbl = out[i];
            if (lbl === 0 || lbl === 1 || lbl === 2) {
              sendTrainingData(maskedTexts[i], lbl, 'cache', true).catch(() => {});
            }
          });
        }
      }

      // 5) 룰 최소 심각도 적용(원문 기준)
      const ruled = out.map((lbl, i) => applyRuleFloorToLabel(originalTexts[i], lbl, rules));

      sendResponse({ labels: ruled, probs: [], label_names: {} });
    })();
    return true; // async
  }

  if (message?.type === 'getSettings') {
    getSettings().then(sendResponse);
    return true;
  }

  if (message?.type === 'incCounter') {
    chrome.action.getBadgeText({}, async (t) => {
      const curr = Number(t || '0') || 0;
      const next = String(curr + (message.by || 1));
      chrome.action.setBadgeText({ text: next });
      chrome.action.setBadgeBackgroundColor({ color: '#d9534f' });
      sendResponse({ ok: true, count: next });
    });
    return true;
  }

  if (message?.type === 'sendTrainingData') {
    sendTrainingData(message.text, message.label, message.userId).then(sendResponse);
    return true;
  }

  return false;
});
