// =============================================
// 학생 마스터('마스터' 시트) → Supabase user_master 동기화
// 시트 전체를 sync_students RPC로 전송 (신규 INSERT / 기존 UPDATE / 빠진 학번 삭제)
//   ※ 이 스크립트는 '마스터' 시트 스프레드시트의 Apps Script에 붙여넣어 사용
// =============================================
const AUTO_SYNC    = false;   // true: 편집 시 자동, false: 수동(syncStudentsToSupabase 직접 실행)

const TARGET_SHEET = '마스터';
// GAS_TOKEN, WORKER_URL은 코드에 평문 저장 금지 — GAS 스크립트 속성에서 조회.
//   등록: GAS 편집기 → 프로젝트 설정(⚙) → 스크립트 속성 →
//     'GAS_TOKEN' : Cloudflare Worker 호출 전용 토큰
//     'WORKER_URL': https://notice-gateway.dshw.workers.dev
function getConfig_() {
  const props = PropertiesService.getScriptProperties();
  return {
    GAS_TOKEN  : props.getProperty('GAS_TOKEN'),
    WORKER_URL : props.getProperty('WORKER_URL'),
  };
}

// 시트 열 (0-based): B=학번, C=성명, D=성별, E=반, F=그룹
const COL = { ID: 1, NAME: 2, SEX: 3, BAN: 4, PRT: 5 };


// ── 트리거 설치 (최초 1회 실행) ──
function installTrigger() {
  ScriptApp.getProjectTriggers().forEach(t => {
    if (t.getHandlerFunction() === 'onSheetEdit') ScriptApp.deleteTrigger(t);
  });
  if (!AUTO_SYNC) {
    Logger.log('AUTO_SYNC가 false입니다. 트리거를 설치하지 않습니다.');
    return;
  }
  ScriptApp.newTrigger('onSheetEdit')
    .forSpreadsheet(SpreadsheetApp.getActiveSpreadsheet())
    .onEdit()
    .create();
  Logger.log('자동 트리거 설치 완료');
}

// ── 트리거 제거 (최초 1회 실행) ──
function removeTrigger() {
  ScriptApp.getProjectTriggers().forEach(t => {
    if (t.getHandlerFunction() === 'onSheetEdit') ScriptApp.deleteTrigger(t);
  });
  Logger.log('자동 트리거 제거 완료');
}

// ── 자동업로드 핸들러 ──
function onSheetEdit(e) {
  if (!AUTO_SYNC) return;
  if (e.source.getActiveSheet().getName() !== TARGET_SHEET) return;
  syncStudentsToSupabase();
}

// ── 전체 업로드 (수동 실행) ──
function syncStudentsToSupabase() {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(TARGET_SHEET);
  if (!sheet) { Logger.log('시트를 찾을 수 없습니다: ' + TARGET_SHEET); return; }

  const rows = sheet.getDataRange().getValues();

  const students = rows
    .slice(1)                                            // 1행 헤더 제외
    .filter(r => String(r[COL.ID]).trim() !== '')        // 학번 빈 행 제외
    .map(r => ({
      mst_id  : String(r[COL.ID]).trim(),
      mst_name: String(r[COL.NAME]).trim(),
      mst_sex : String(r[COL.SEX]).trim(),
      mst_ban : String(r[COL.BAN]).trim(),
      mst_prt : String(r[COL.PRT]).trim()
      // mst_lnce(비고)는 시트에 없음 → 생략(DB에서 null)
    }));

  if (students.length === 0) { Logger.log('전송할 학생이 없습니다.'); return; }

  const cfg = getConfig_();
  const res = UrlFetchApp.fetch(cfg.WORKER_URL, {
    method      : 'POST',
    contentType : 'application/json',
    headers     : { 'X-Call-Token': cfg.GAS_TOKEN },
    payload     : JSON.stringify({ action: 'sync_students', payload: { p_students: students } }),
    muteHttpExceptions: true
  });

  Logger.log('응답코드: ' + res.getResponseCode());
  Logger.log('응답본문: ' + res.getContentText());        // {success, inserted, updated, deleted}
  Logger.log('전송: ' + students.length + '건');
}
