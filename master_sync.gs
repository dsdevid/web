// =============================================
// 학생 마스터('마스터' 시트) → Supabase user_master 동기화
// 시트 전체를 sync_students RPC로 전송 (신규 INSERT / 기존 UPDATE / 빠진 학번 삭제)
//   ※ 이 스크립트는 '마스터' 시트 스프레드시트의 Apps Script에 붙여넣어 사용
// =============================================
const AUTO_SYNC    = false;   // true: 편집 시 자동, false: 수동(syncStudentsToSupabase 직접 실행)

const TARGET_SHEET = '마스터';
const SUPABASE_URL = 'https://rwplqifhmlduukipnksm.supabase.co';
// ⚠ secret/service_role 키 (서버 전용 — 절대 브라우저 노출/커밋 금지).
//    sync_students 는 anon 미부여 → 서버 키 필요.
//    코드에 평문 저장 금지 → GAS 스크립트 속성에서 조회.
//    등록: GAS 편집기 → 프로젝트 설정(⚙) → 스크립트 속성 → 'SUPABASE_KEY' 값 입력
const SUPABASE_KEY = PropertiesService.getScriptProperties().getProperty('SUPABASE_KEY');

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

  const res = UrlFetchApp.fetch(`${SUPABASE_URL}/rest/v1/rpc/sync_students`, {
    method      : 'POST',
    contentType : 'application/json',
    headers     : {
      'apikey'        : SUPABASE_KEY,
      'Authorization' : `Bearer ${SUPABASE_KEY}`
    },
    payload : JSON.stringify({ p_students: students }),  // RPC 인자명 p_students
    muteHttpExceptions: true
  });

  Logger.log('응답코드: ' + res.getResponseCode());
  Logger.log('응답본문: ' + res.getContentText());        // {success, inserted, updated, deleted}
  Logger.log('전송: ' + students.length + '건');
}
