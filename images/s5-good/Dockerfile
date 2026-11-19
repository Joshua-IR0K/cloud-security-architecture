# ============================================================
# s5-good — Stage 5 정상 이미지 (검증 축 ②)
# ============================================================
# 목적: 스캔을 통과하고 EKS 에 배포되는 "골든" 이미지.
#
# 설계 의도:
#   - 최신 alpine 기반 nginx = 취약점 표면 최소
#   - S1~S3 에서 쓰던 차별화 페이지를 이미지에 내장
#     (지금까지는 ConfigMap 마운트였다 — 이제 이미지가 콘텐츠를 소유)
#
# [3단계 파트 1, 2026-10] 베이스 교체 + tag@digest 고정 (위협모델 G4·G8)
#   nginx:stable-alpine (root 로 시작, 포트 80)
#     → nginx-unprivileged:<버전>-alpine-slim (UID 101 비루트, 포트 8080)
#   · 왜 먼저인가 — 파트 2 의 securityContext(runAsNonRoot·capabilities 전부 제거)와
#     app 네임스페이스 PSA restricted 는 비루트 이미지를 전제로 한다. 기존 이미지에 그 제약을
#     걸면 파드가 뜨지 못한다 (root 시작 거부 / 80 포트 바인딩·캐시 디렉터리 권한 거부).
#   · alpine-slim — 정적 페이지 서빙에 필요 없는 동적 모듈(njs·xslt·geoip·image-filter)을 뺀 변형
#   · tag@digest — 태그는 사람이 읽는 버전, digest 가 실제 내용이다.
#     이 베이스는 업스트림이 매주(월요일) 재빌드해 같은 태그가 다른 이미지로 옮겨 간다.
#     digest 를 박아 두면 빌드 입력이 조용히 바뀌지 않고, 갱신은 Dependabot(docker) PR 이
#     tag·digest 를 함께 올린 뒤 CI 의 Trivy 게이트가 검증한다.
#   · ECR Public 미러 — Docker Hub 익명 pull 의 IP 당 rate limit 회피 (기존 원칙 유지)
# ============================================================

FROM public.ecr.aws/nginx/nginx-unprivileged:1.30.7-alpine-slim@sha256:8432c57ac86f178741af2b89948bd9087cb9df1c415bc1ab4d23735c4f0e3e61

# 패키지 갱신·파일 배치는 root 권한이 필요하다 — 빌드 구간만 root, 마지막에 101 로 되돌린다
USER root

# ── 빌드 시점 보안 패치 ───────────────────────────────────
# 왜 필요한가 (2026-08 실증):
#   공식 base image(nginx:stable-alpine)를 그대로 썼는데도 Trivy 게이트가
#   CVE-2026-14456 (libcrypto3/libssl3, HIGH)을 잡았다.
#   Status=fixed, 즉 **업스트림에 이미 패치가 있는데 base image 가 아직
#   그 패치로 재빌드되지 않은 상태**였다.
#   → "공식 이미지를 쓰면 안전하다"는 가정이 깨지는 지점이며,
#     빌드타임 게이트가 존재하는 이유 그 자체다.
#
# 대응 선택 (기록):
#   ✗ 게이트를 CRITICAL 로 낮춤    — 문제를 없앤 게 아니라 안 보이게 하는 것
#   ✗ .trivyignore 예외            — 수정 불가 취약점엔 타당하나 여긴 패치가 있음
#   ✓ 패키지 갱신으로 실제 해소     — 게이트를 유지하고 취약점을 제거
#
# ⚠ 트레이드오프: apk upgrade 는 빌드 시점에 따라 결과가 달라져 재현성이 낮다.
#   보완: 입력(베이스)은 digest 로 고정하고, 출력(우리 이미지)은 CI 가 기록한 digest 로
#   배포한다(파트 2). 서명으로 출처까지 묶는 것은 S7.
RUN apk --no-cache upgrade

LABEL org.opencontainers.image.title="s5-good" \
      org.opencontainers.image.description="Phase 4B Stage 5 golden image" \
      org.opencontainers.image.vendor="joshua-devsecops"

# ── 애플리케이션 콘텐츠는 "이미지"가 소유한다 (P1-6) ──────
# 기존에는 K8s ConfigMap 이 /usr/share/nginx/html 을 마운트해 이미지의
# index.html 을 통째로 가렸다. 그러면 HTTPS 응답으로 "어느 커밋의 이미지가
# 도는지" 확인할 수 없어 E2E 증거 사슬(commit → image → pod → response)이 끊긴다.
#   Docker Image → application artifact
#   ConfigMap    → runtime configuration
# 이 분리를 지키기 위해 05-k8s 의 ConfigMap 마운트를 제거했다.
COPY index.html /usr/share/nginx/html/index.html

# ── build identity 각인 (P1-6) ────────────────────────────
# 이미지가 애플리케이션 콘텐츠를 소유하고, 어느 커밋의 산출물인지 페이지에 새긴다.
# → HTTPS 응답만 보고 Git commit → build → ECR → Deployment → Pod 가 연결됨을 확인.
#   (ConfigMap 이 html 을 마운트하면 이 값이 가려지므로 마운트를 제거했다)
# 로컬 빌드는 기본값 "local", CI 는 --build-arg BUILD_SHA=<github.sha>
ARG BUILD_SHA=local
RUN sed -i "s|__BUILD_SHA__|${BUILD_SHA}|g" /usr/share/nginx/html/index.html

# ── 런타임은 비루트 ───────────────────────────────────────
# 베이스 이미지의 nginx 사용자(UID 101). 숫자로 적어야 kubelet 의 runAsNonRoot 검증이
# 이미지 메타데이터만으로 성립한다 (이름이면 UID 를 알 수 없어 거부될 수 있다).
USER 101

# 1024 미만 포트를 쓰지 않으므로 바인딩 권한(CAP_NET_BIND_SERVICE)이 필요 없다
EXPOSE 8080
