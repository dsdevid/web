// =============================================
// 설정값 - 환경에 맞게 수정
// =============================================
// SUPABASE_KEY(service_role)는 코드에 평문 저장 금지 — GAS 스크립트 속성에서 조회.
//   등록: GAS 편집기 → 프로젝트 설정(⚙) → 스크립트 속성 → 속성 'SUPABASE_KEY' 값 입력
const CONFIG = {
  SUPABASE_URL  : 'https://rwplqifhmlduukipnksm.supabase.co',
  SUPABASE_KEY  : PropertiesService.getScriptProperties().getProperty('SUPABASE_KEY'),
  SHEET_NAME    : '공지사항',
  TABLE_NAME    : 'user_textnotice',
};

// 열 인덱스 (1-based)
const COL = {
  CHECK  : 1,  // A: 선택 (체크박스)
  ID     : 2,  // B: id (Supabase 반환 id 기록용)
  DATE   : 3,  // C: 일시
  OWNER  : 4,  // D: 작성자
  TITLE  : 5,  // E: 제목
  BODY   : 6,  // F: 내용
  READCNT: 7,  // G: 읽음
  HIDDEN : 8,  // H: 게시 (TRUE = 게시 = hidden FALSE)
};

// =============================================
// onEdit 트리거 - A열 체크 시 자동 실행
// =============================================
function onSheetEdit(e) {
  if (!e || !e.range) return;
  const { range, value, source } = e;

  const isCheckCol    = range.getColumn() === COL.CHECK;
  const isChecked     = value === 'TRUE';
  const sheet         = source.getActiveSheet();
  const isTargetSheet = sheet.getName() === CONFIG.SHEET_NAME;
  const isDataRow     = range.getRow() > 1;

  if (!isCheckCol || !isChecked || !isTargetSheet || !isDataRow) return;

  const row = range.getRow();
  sendRowToSupabase(sheet, row);
}

// =============================================
// 단일 행 Supabase 전송
// =============================================
function sendRowToSupabase(sheet, row) {
  const rowData = sheet.getRange(row, 1, 1, COL.HIDDEN).getValues()[0];

  const existingId  = rowData[COL.ID - 1];
  const dateVal     = rowData[COL.DATE - 1];
  const owner       = rowData[COL.OWNER - 1];
  const title       = rowData[COL.TITLE - 1];
  const body        = rowData[COL.BODY - 1];
  const readCnt     = rowData[COL.READCNT - 1] || 0;
  const isPublished = rowData[COL.HIDDEN - 1]; // TRUE = 게시중

  // 필수값 검증
  if (!owner || !title || !body) {
    showToast_(sheet, row, '❌ 작성자, 제목, 내용은 필수입니다');
    uncheckRow_(sheet, row);
    return;
  }

  // 날짜 포맷 (YYYY-MM-DD)
  const noticeDate = dateVal
    ? Utilities.formatDate(new Date(dateVal), Session.getScriptTimeZone(), "yyyy-MM-dd'T'HH:mm:ss+09:00")
    : Utilities.formatDate(new Date(), Session.getScriptTimeZone(), "yyyy-MM-dd'T'HH:mm:ss+09:00");

  const payload = {
    textnotice_date  : noticeDate,
    textnotice_owner : String(owner),
    textnotice_title : String(title),
    textnotice_body  : String(body),
    // readcnt, hidden은 DB에서 관리 — 시트에서 덮어쓰지 않음
  };

  try {
    let responseData;

    if (existingId) {
      const existing = getFromSupabase_(`?textnotice_id=eq.${existingId}`);

      if (!existing || !existing[0]) {
        showToast_(sheet, row, '❌ DB에서 기존 데이터를 찾을 수 없습니다');
        uncheckRow_(sheet, row);
        setRowColor_(sheet, row, '#FFE0E0');
        return;
      }

      if (!hasChanged_(existing[0], payload)) {
        showToast_(sheet, row, '⚠️ 변경 내용이 없습니다');
        uncheckRow_(sheet, row);
        return;
      }

      responseData = supabaseRequest_('PATCH', `?textnotice_id=eq.${existingId}`, payload);
      showToast_(sheet, row, `✅ 업데이트 완료 (id: ${existingId})`);
    } else {
      // 신규 INSERT
      responseData = supabaseRequest_('POST', '', payload);
      // 반환된 id를 B열에 기록
      if (responseData && responseData[0]?.textnotice_id) {
        sheet.getRange(row, COL.ID).setValue(responseData[0].textnotice_id);
      }
      showToast_(sheet, row, '✅ 등록 완료');
    }

    uncheckRow_(sheet, row); // 전송 후 체크 해제
    setRowColor_(sheet, row, '#FFFFFF'); // 성공 시 배경 초기화

  } catch (err) {
    showToast_(sheet, row, `❌ 오류: ${err.message}`);
    uncheckRow_(sheet, row);
    setRowColor_(sheet, row, '#FFE0E0'); // 오류 시 배경 빨간색
  }
}

// =============================================
// Supabase REST API 요청 공통 함수
// =============================================
function supabaseRequest_(method, query, payload) {
  const url = `${CONFIG.SUPABASE_URL}/rest/v1/${CONFIG.TABLE_NAME}${query}`;

  const options = {
    method      : method,
    contentType : 'application/json',
    headers     : {
      'apikey'        : CONFIG.SUPABASE_KEY,
      'Authorization' : `Bearer ${CONFIG.SUPABASE_KEY}`,
      'Prefer'        : 'return=representation',
      'Content-Type'  : 'application/json',  // ← 명시적 추가
    },
    payload     : JSON.stringify(payload),
    muteHttpExceptions: true,
  };

  const response = UrlFetchApp.fetch(url, options);
  const statusCode = response.getResponseCode();
  const responseText = response.getContentText();

  if (statusCode < 200 || statusCode >= 300) {
    throw new Error(`HTTP ${statusCode}: ${responseText}`);
  }

  return JSON.parse(responseText);
}

// =============================================
// 유틸 함수
// =============================================
function uncheckRow_(sheet, row) {
  sheet.getRange(row, COL.CHECK).setValue(false);
}

function showToast_(sheet, row, message) {
  SpreadsheetApp.getActiveSpreadsheet().toast(
    `${row}행 - ${message}`,
    '공지사항 전송',
    4
  );
}

function setRowColor_(sheet, row, color) {
  sheet.getRange(row, COL.CHECK, 1, COL.HIDDEN)
       .setBackground(color);
}

// DB에서 단일 행 조회
function getFromSupabase_(query) {
  const url = `${CONFIG.SUPABASE_URL}/rest/v1/${CONFIG.TABLE_NAME}${query}`;
  const response = UrlFetchApp.fetch(url, {
    method  : 'GET',
    headers : {
      'apikey'        : CONFIG.SUPABASE_KEY,
      'Authorization' : `Bearer ${CONFIG.SUPABASE_KEY}`,
    },
    muteHttpExceptions: true,
  });
  if (response.getResponseCode() !== 200) return null;
  return JSON.parse(response.getContentText());
}

// 시트 데이터와 DB 데이터 변경 여부 비교
function hasChanged_(dbRow, payload) {
  const dbDate      = dbRow.textnotice_date
    ? dbRow.textnotice_date.substring(0, 19)
    : '';
  const payloadDate = payload.textnotice_date
    ? payload.textnotice_date.substring(0, 19)
    : '';

  return (
    dbDate                 !== payloadDate              ||
    dbRow.textnotice_owner !== payload.textnotice_owner ||
    dbRow.textnotice_title !== payload.textnotice_title ||
    dbRow.textnotice_body  !== payload.textnotice_body
  );
}

// =============================================
// ※ 웹 프론트엔드는 Cloudflare Pages로 이전
//   인증/대시보드는 Supabase REST API 직접 호출
//   이 파일은 Google Sheets 연동 전용
// =============================================

// =================================================================================
// 등록을 위해 최초 1회 실행
// =================================================================================
function installTrigger() {
  ScriptApp.getProjectTriggers().forEach(t => {
    ScriptApp.deleteTrigger(t);
  });

  // onSheetEdit 으로 변경
  ScriptApp.newTrigger('onSheetEdit')
    .forSpreadsheet(SpreadsheetApp.getActiveSpreadsheet())
    .onEdit()
    .create();

  console.log('트리거 등록 완료:', ScriptApp.getProjectTriggers().length);
}





