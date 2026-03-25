// 환경변수로 주입: k6 run -e BASE_URL=http://localhost:8000 -e API_KEY=xxx
export const BASE_URL = __ENV.BASE_URL || "http://localhost:8000";
export const API_KEY  = __ENV.API_KEY  || "";

export const COMMENTS = [
  "이 방송 너무 재밌다ㅋㅋㅋ",
  "저 ㅂㅅ같은 놈 꺼져라",
  "와 진짜 대박이다",
  "닥쳐 ㅡㅡ",
  "항상 응원합니다!",
  "쓰레기 같은 방송이네",
  "오늘도 좋은 방송 감사해요",
  "이런 거 보는 애들 다 병신",
  "너무 웃겨 ㅋㅋㅋㅋ",
  "진짜 최고다",
  "나가 뒤져라",
  "감사합니다 덕분에 힐링했어요",
];

export function randomComment() {
  return COMMENTS[Math.floor(Math.random() * COMMENTS.length)];
}

export function authHeaders() {
  const h = { "Content-Type": "application/json" };
  if (API_KEY) h["X-API-Key"] = API_KEY;
  return h;
}
