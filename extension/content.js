// === YouTube Live Chat Filter (content script, auto-apply & show-all fix) ===

const STATE = {
    enabled: true,
    queue: [],
    pending: false,
    labelOfMessageId: new Map(),
    minSeverityToHide: 2,
    action: 'hide',            // 'hide' | 'blur' | 'delete'
    showBadge: true,
    trainingMode: false,       // 학습 데이터 수집 모드
  
    // 디듀프/GC
    enqueuedIds: new Set(),
    processedIds: new Set(),
  
    // 설정
    BATCH_SIZE: 20,
    PROCESSED_LIMIT: 4000,

    // 부하 제어
    THROTTLE_MS: 200,          // 분류 호출 간 최소 간격
    MAX_QUEUE: 300,            // 큐 상한 (초과 시 오래된 항목 드롭)
    lastFlushAt: 0,
    flushTimer: null,
    bulkModeUntilTs: 0,        // 대량 DOM 갱신 감지 시 지연 처리
  };
  
  function sleep(ms){ return new Promise(r => setTimeout(r, ms)); }
  
  async function loadSettings() {
    return new Promise((resolve) => {
      chrome.storage.local.get({ enabled: true, minSeverityToHide: 2, action: 'hide', showBadge: true, trainingMode: false }, (cfg) => {
        STATE.enabled = cfg.enabled !== false;
        STATE.minSeverityToHide = Number(cfg.minSeverityToHide ?? 2);
        STATE.action = cfg.action ?? 'hide';
        STATE.showBadge = !!cfg.showBadge;
        STATE.trainingMode = !!cfg.trainingMode;
        resolve(cfg);
      });
    });
  }
  
  /* ---------------- DOM 헬퍼 ---------------- */
  
  function getMessageElFromRenderer(renderer) {
    if (!renderer) return null;
    let msg = renderer.querySelector && renderer.querySelector('#message');
    if (msg) return msg;
    if (renderer.shadowRoot) {
      msg = renderer.shadowRoot.querySelector('#message');
      if (msg) return msg;
    }
    return null;
  }
  
  function getChatMessageElementsUnique() {
    const out = [];
    const renderers = document.querySelectorAll('yt-live-chat-text-message-renderer');
    for (const r of renderers) {
      const el = getMessageElFromRenderer(r);
      if (el) out.push(el);
    }
    return out;
  }
  
  function getMessageText(el) {
    return el?.textContent?.trim() || '';
  }
  
  /* ---------------- 안정 키 ---------------- */
  
  function stableHash(s) {
    let h = 0, i = 0, len = s.length;
    while (i < len) h = (h * 31 + s.charCodeAt(i++)) | 0;
    return String(h >>> 0);
  }
  
  function messageKey(el) {
    const host = el.closest('yt-live-chat-text-message-renderer');
    if (!host) return 't:' + stableHash(getMessageText(el));
  
    const domId = host.getAttribute('id');
    if (domId) return domId;
  
    const author = (host.querySelector?.('#author-name')?.textContent || '').trim();
    const ts = host.getAttribute('timestamp') || host.dataset?.timestamp || '';
    const text = getMessageText(el);
  
    return 'k:' + stableHash([author, ts, text].join('|'));
  }
  
  /* ---------------- 배지/행동 ---------------- */
  
  function applyBadge(el, label) {
    if (!STATE.showBadge || STATE.enabled === false) return;
    const host = el.closest('yt-live-chat-text-message-renderer');
    const container = host || el;
    if (!container) return;
    if (container.querySelector('.ylcf-badge')) return;
  
    const badge = document.createElement('span');
    badge.className = 'ylcf-badge';
    badge.textContent = label === 2 ? '악성' : (label === 1 ? '약간 악성' : '정상');
  
    const bg = (label===2 ? '#d9534f' : (label===1 ? '#f0ad4e' : '#5bc0de'));
    badge.style.cssText = [
      'margin-left:6px',
      'padding:2px 6px',
      'border-radius:10px',
      'font-size:10px',
      `background:${bg}`,
      'color:#fff',
    ].join(';');
  
    const header = container.querySelector('#author-name') || container.querySelector('#message');
    if (header) header.appendChild(badge);
  }

  /* ---------------- 학습 데이터 수집 ---------------- */

  function showLabelingDialog(text) {
    const dialog = document.createElement('div');
    dialog.style.cssText = [
      'position:fixed', 'top:50%', 'left:50%', 'transform:translate(-50%,-50%)',
      'background:#2a2a2a', 'border:1px solid #3a3a3a', 'border-radius:12px',
      'padding:20px', 'z-index:10000', 'min-width:300px', 'box-shadow:0 8px 32px rgba(0,0,0,0.5)'
    ].join(';');

    dialog.innerHTML = `
      <div style="color:#eaeaea; font-size:14px; margin-bottom:15px;">
        다음 댓글의 라벨을 선택하세요:
      </div>
      <div style="background:#1d1d1d; padding:10px; border-radius:8px; margin-bottom:15px; font-size:13px; color:#eaeaea; max-height:100px; overflow-y:auto;">
        ${text}
      </div>
      <div style="display:flex; gap:10px; justify-content:center;">
        <button class="label-btn" data-label="0" style="padding:8px 16px; border:none; border-radius:8px; background:#5bc0de; color:#fff; cursor:pointer;">정상</button>
        <button class="label-btn" data-label="1" style="padding:8px 16px; border:none; border-radius:8px; background:#f0ad4e; color:#fff; cursor:pointer;">약간 악성</button>
        <button class="label-btn" data-label="2" style="padding:8px 16px; border:none; border-radius:8px; background:#d9534f; color:#fff; cursor:pointer;">악성</button>
      </div>
      <div style="text-align:center; margin-top:10px;">
        <button id="cancel-btn" style="padding:6px 12px; border:none; border-radius:6px; background:#3a3a3a; color:#eaeaea; cursor:pointer;">취소</button>
      </div>
    `;

    document.body.appendChild(dialog);

    return new Promise((resolve) => {
      dialog.querySelectorAll('.label-btn').forEach(btn => {
        btn.addEventListener('click', () => {
          const label = parseInt(btn.dataset.label);
          document.body.removeChild(dialog);
          resolve(label);
        });
      });

      dialog.querySelector('#cancel-btn').addEventListener('click', () => {
        document.body.removeChild(dialog);
        resolve(null);
      });
    });
  }

  async function handleTrainingClick(el) {
    if (!STATE.trainingMode) return;
    
    const text = getMessageText(el);
    if (!text) return;

    const label = await showLabelingDialog(text);
    if (label !== null) {
      try {
        const result = await chrome.runtime.sendMessage({
          type: 'sendTrainingData',
          text: text,
          label: label,
          userId: 'user'
        });
        
        if (result.success) {
          // 성공 시 시각적 피드백
          const host = el.closest('yt-live-chat-text-message-renderer');
          const container = host || el;
          if (container) {
            container.style.border = '2px solid #5bc0de';
            container.style.borderRadius = '8px';
            setTimeout(() => {
              container.style.border = '';
              container.style.borderRadius = '';
            }, 2000);
          }
        }
      } catch (e) {
        console.error('Failed to send training data:', e);
      }
    }
  }
  
  // ---- 조치 되돌리기용 유틸 ----
  function markActed(target, how) {
    target.classList.add('ylcf-acted');
    target.dataset.ylcfAction = how; // 'hide' | 'blur' | 'delete'
  }
  function unapplyOne(target) {
    if (!(target instanceof HTMLElement)) return;
    // 우리가 붙인 스타일만 되돌림
    if (target.style.filter) target.style.filter = '';
    if (target.style.opacity) target.style.opacity = '';
    if (target.style.pointerEvents) target.style.pointerEvents = '';
    if (target.style.display === 'none') target.style.display = '';
    target.classList.remove('ylcf-acted');
    delete target.dataset.ylcfAction;
  }
  function unapplyAllActions() {
    document.querySelectorAll('.ylcf-acted').forEach(unapplyOne);
  }

  function removeAllBadges() {
    document.querySelectorAll('.ylcf-badge').forEach(el => el.parentElement && el.parentElement.removeChild(el));
  }
  
  function actOnSevere(el, label) {
    if (STATE.enabled === false) return;
    // ★ 임계치 0 = "모두 표시" → 어떤 조치도 하지 않음
    if (STATE.minSeverityToHide === 0) return;
  
    // 임계치 미만은 조치 안 함
    if (label < STATE.minSeverityToHide) return;
  
    const host = el.closest('yt-live-chat-text-message-renderer');
    const target = host || el;
    if (!target) return;
  
    let acted = false;
    if (STATE.action === 'hide') {
      target.style.display = 'none';
      markActed(target, 'hide');
      acted = true;
    } else if (STATE.action === 'blur') {
      target.style.filter = 'blur(6px)';
      target.style.opacity = '0.5';
      // pointerEvents는 유지하여 클릭 수집 허용
      markActed(target, 'blur');
      acted = true;
    } else if (STATE.action === 'delete') {
      // 실패 시 숨김으로 폴백
      const menu = target.querySelector('#menu button[aria-label]');
      if (menu) {
        menu.click();
        setTimeout(() => {
          const del = document.querySelector(
            'tp-yt-paper-listbox tp-yt-paper-item[aria-label*="삭제"], ' +
            'tp-yt-paper-listbox tp-yt-paper-item[aria-label*="Remove"], ' +
            'tp-yt-paper-listbox tp-yt-paper-item[aria-label*="Hide"]'
          );
          if (del && del instanceof HTMLElement) {
            del.click();
          } else {
            target.style.display = 'none';
          }
          markActed(target, 'delete');
        }, 200);
        acted = true;
      } else {
        target.style.display = 'none';
        markActed(target, 'delete');
        acted = true;
      }
    }
  
    if (acted) {
      try { chrome.runtime.sendMessage({ type: 'incCounter', by: 1 }, () => {}); } catch {}
    }
  }
  
  /* ---------------- 큐 처리 ---------------- */
  
  function gcProcessedIds() {
    if (STATE.processedIds.size <= STATE.PROCESSED_LIMIT) return; //PROCESSED_LIMIT 초과 시 절반씩 버리기 , 기준 4000
    const next = new Set();
    let i = 0;
    for (const id of STATE.processedIds) {
      if (++i % 2 === 0) next.add(id);
    }
    STATE.processedIds = next;
  }
  
  function dropOverflow() {
    if (STATE.queue.length <= STATE.MAX_QUEUE) return; //MAX_QUEUE 초과 시 오래된 항목 드롭, 기준 300
    const keep = STATE.queue.slice(-STATE.MAX_QUEUE);
    const keepIds = new Set(keep.map(it => it.id));
    STATE.queue = keep;
    // enqueuedIds를 보정
    STATE.enqueuedIds.forEach(id => { if (!keepIds.has(id)) STATE.enqueuedIds.delete(id); });
  }

  function scheduleFlush() {
    if (STATE.enabled === false) return;
    if (STATE.flushTimer) return;
    const now = Date.now();
    let delay = Math.max(0, STATE.lastFlushAt + STATE.THROTTLE_MS - now); //THROTTLE_MS 간격 유지하여 flush 예약
    // 대량 갱신 모드면 추가 지연
    if (now < STATE.bulkModeUntilTs) delay = Math.max(delay, 400);
    STATE.flushTimer = setTimeout(() => {
      STATE.flushTimer = null;
      STATE.lastFlushAt = Date.now();
      flushQueue();
    }, delay);
  }

  async function flushQueue() {
    if (STATE.enabled === false || STATE.pending || STATE.queue.length === 0) return;
    STATE.pending = true;
  
    // 큐 길이에 따라 배치 크기를 유동적으로 조정 (버스트 대응)
    const dynamicBatch = STATE.queue.length > 200 ? 100 : STATE.BATCH_SIZE;
    //BATCH_SIZE는 기본 배치 크기, 200개 이상 대기 시 100개로 늘려 빠르게 처리 (버스트 대응)

    const batch = STATE.queue.splice(0, dynamicBatch);
    const texts = batch.map(b => b.text);
  
    try {
      const res = await chrome.runtime.sendMessage({ type: 'classify', texts });
      const labels = res?.labels || [];
  
      batch.forEach((item, idx) => {
        const label = labels[idx] ?? 0;
        STATE.labelOfMessageId.set(item.id, label);
        STATE.processedIds.add(item.id);
        STATE.enqueuedIds.delete(item.id);
  
        applyBadge(item.el, label);
        actOnSevere(item.el, label);
      });
  
      gcProcessedIds();
    } catch (e) {
      batch.forEach(item => STATE.enqueuedIds.delete(item.id));
    } finally {
      STATE.pending = false;
      if (STATE.queue.length > 0) scheduleFlush();
    }
  }
  
  function enqueueForClassification(el) {
    if (STATE.enabled === false) return;
    const text = getMessageText(el);
    if (!text) return;
  
    const id = messageKey(el);
    if (STATE.processedIds.has(id) || STATE.enqueuedIds.has(id)) return;
  
    STATE.enqueuedIds.add(id);
    STATE.queue.push({ id, text, el });
    dropOverflow();
    scheduleFlush();
  }

  function setupTrainingClick(el) {
    if (!STATE.trainingMode) return;
    
    const host = el.closest('yt-live-chat-text-message-renderer');
    const container = host || el;
    if (!container) return;
    
    // 이미 클릭 이벤트가 설정된 경우 중복 방지
    if (container.dataset.ylcfTrainingClick) return;
    container.dataset.ylcfTrainingClick = 'true';
    
    container.style.cursor = 'pointer';
    container.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      // blur 상태면 2초간 원본 노출
      if (container.dataset.ylcfAction === 'blur') {
        const prevFilter = container.style.filter;
        const prevOpacity = container.style.opacity;
        container.style.filter = '';
        container.style.opacity = '';
        setTimeout(() => {
          if (container.dataset.ylcfAction === 'blur') {
            container.style.filter = prevFilter || 'blur(6px)';
            container.style.opacity = prevOpacity || '0.5';
          }
        }, 2000);
      }
      handleTrainingClick(el);
    });
  }

  function updateTrainingMode() {
    const containers = document.querySelectorAll('yt-live-chat-text-message-renderer');
    containers.forEach(container => {
      if (STATE.trainingMode) {
        if (!container.dataset.ylcfTrainingClick) {
          container.style.cursor = 'pointer';
          container.dataset.ylcfTrainingClick = 'true';
          container.addEventListener('click', (e) => {
            e.preventDefault();
            e.stopPropagation();
            const msgEl = getMessageElFromRenderer(container);
            if (msgEl) handleTrainingClick(msgEl);
          });
        }
      } else {
        if (container.dataset.ylcfTrainingClick) {
          container.style.cursor = '';
          delete container.dataset.ylcfTrainingClick;
          // 이벤트 리스너는 제거하기 어려우므로 무시
        }
      }
    });
  }
  
  /* ---------------- 옵저버 ---------------- */
  
  function observeLiveChat() {
    const root = document;
    const observer = new MutationObserver((records) => {
      if (STATE.enabled === false) return; // 비활성화 시 관찰 이벤트 무시
      let addedCount = 0;
      for (const rec of records) {
        for (const node of rec.addedNodes) {
          if (!(node instanceof Element)) continue;
  
          if (node.matches?.('yt-live-chat-text-message-renderer')) {
            const msgEl = getMessageElFromRenderer(node);
            if (msgEl) {
              enqueueForClassification(msgEl);
              setupTrainingClick(msgEl);
              addedCount++;
            }
            continue;
          }
          node.querySelectorAll?.('yt-live-chat-text-message-renderer').forEach(r => {
            const msgEl = getMessageElFromRenderer(r);
            if (msgEl) {
              enqueueForClassification(msgEl);
              setupTrainingClick(msgEl);
              addedCount++;
            }
          });
        }
      }

      // 대량 DOM 추가 감지 시 잠시 모아 처리 (버스트 흡수)
      if (addedCount >= 120) {
        STATE.bulkModeUntilTs = Date.now() + 1500;
      }
      scheduleFlush();
    });
  
    observer.observe(root.body || root, { childList: true, subtree: true });
    getChatMessageElementsUnique().forEach(el => {
      enqueueForClassification(el);
      setupTrainingClick(el);
    });
  }
  
  /* ---------------- 설정 변경 자동 적용 ---------------- */
  
  function installAutoApply() {
    chrome.storage.onChanged.addListener((changes, area) => {
      if (area !== 'local') return;
  
      let needUnapply = false;
  
      if (changes.minSeverityToHide) {
        STATE.minSeverityToHide = Number(changes.minSeverityToHide.newValue);
        // 임계치가 0(모두 표시)이면 기존 조치들 즉시 되돌림
        if (STATE.minSeverityToHide === 0) needUnapply = true;
      }
      if (changes.action) {
        STATE.action = changes.action.newValue;
        // 동작 방식 바꾸면 기존 조치와 충돌할 수 있으니 정리
        needUnapply = true;
      }
      if (changes.showBadge) {
        STATE.showBadge = !!changes.showBadge.newValue;
        // 배지는 새 메시지부터 반영. (원하면 여기서 기존 배지 제거도 가능)
      }
      if (changes.trainingMode) {
        STATE.trainingMode = !!changes.trainingMode.newValue;
        // 학습 모드 변경 시 기존 메시지들에 클릭 이벤트 설정/제거
        updateTrainingMode();
      }
  
      if (changes.enabled) {
        STATE.enabled = changes.enabled.newValue !== false;
        if (!STATE.enabled) {
          // 비활성화시 즉시 모든 조치/배지 제거
          unapplyAllActions();
          removeAllBadges();
          STATE.queue = [];
          STATE.enqueuedIds.clear();
        } else {
          // 재활성화 시 현재 보이는 메시지 재평가
          getChatMessageElementsUnique().forEach(el => enqueueForClassification(el));
        }
      }

      if (needUnapply) unapplyAllActions();
    });
  }
  
  /* ---------------- 엔트리포인트 ---------------- */
  
  (async function main(){
    try {
      await loadSettings();
      if (!location.href.includes('youtube.com')) return;
  
      // 라이브 채팅 노출 대기
      for (let i = 0; i < 40; i++) {
        const els = getChatMessageElementsUnique();
        if (els.length > 0) break;
        await sleep(500);
      }
  
      observeLiveChat();
      installAutoApply(); // ★ 설정 변경 자동 반영
    } catch (e) {
      console.error('ylcf content error:', e);
    }
  })();
  