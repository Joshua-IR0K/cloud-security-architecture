# ============================================================
# s5-good — Stage 5 정상 이미지 (검증 축 ②)
# ============================================================
# 목적: 스캔을 통과하고 EKS 에 배포되는 "골든" 이미지.
#
# 설계 의도:
#   - 최신 alpine 기반 nginx = 취약점 표면 최소
#   - S1~S3 에서 쓰던 차별화 페이지를 이미지에 내장
#     (지금까지는 ConfigMap 마운트였다 — 이제 이미지가 콘텐츠를 소유)
#   - 비루트 실행은 S7 의 Kyverno/PSA 에서 정책으로 강제할 예정이므로
#     여기서는 nginx 기본 구성을 유지 (한 스테이지에 변수 하나)
# ============================================================

# ⚠ 태그가 아니라 digest 로 핀하는 것이 S7 의 주제다.
#   Stage 5 에서는 태그를 쓰되, "왜 태그가 위험한가"를 IMMUTABLE 실증으로 보인다.
FROM public.ecr.aws/docker/library/nginx:stable-alpine

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
#   S7 에서 digest 핀 + 서명으로 "무엇이 실제 배포됐는가"를 고정해 보완한다.
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

EXPOSE 80
