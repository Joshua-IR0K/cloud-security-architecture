# ============================================================
# s5-good — Stage 5 정상 이미지 / Stage 7 공급망 검증 기준 이미지
# ============================================================
# 목적:
#   - Trivy/Inspector 보안 게이트를 통과하고 EKS에 배포되는 기준 이미지
#   - Stage 7에서는 이 이미지의 ECR canonical digest를 기준으로
#     KMS/Cosign 서명 → 검증 → Kyverno Admission까지 신뢰 사슬을 검증
#
# 설계 의도:
#   - nginx stable-alpine 계열을 사용해 불필요한 패키지와 공격 표면을 줄임
#   - base image를 tag가 아닌 digest로 고정해 빌드 입력의 변동성을 줄임
#   - S1~S3에서 사용하던 차별화 페이지를 이미지에 내장
#     (기존 ConfigMap 마운트에서 application artifact ownership을 이미지로 이전)
#   - 컨테이너 실행 권한 hardening(runAsNonRoot, capabilities, seccomp 등)은
#     Stage 7 이후 PSA/securityContext hardening 단계에서 별도로 적용
#     → Stage 7에서는 image supply-chain trust에 변수 범위를 한정
# ============================================================

# ── Base image identity 고정 ─────────────────────────────────
# tag(stable-alpine)는 시간이 지나면 다른 이미지 digest를 가리킬 수 있으므로,
# 실제 빌드에 사용한 upstream base image를 digest로 고정한다.
#
# 목적:
#   1. 동일 commit의 빌드 입력을 더 명확하게 식별
#   2. upstream tag 이동으로 base image가 조용히 바뀌는 것을 방지
#   3. Dependabot 등 명시적 변경을 통해 base image 갱신 이력을 Git에 남김
#
# ⚠ 이 digest는 "base image의 identity"다.
#   Stage 7에서 서명·검증·배포하는 최종 artifact identity는
#   ECR push 이후 확정되는 별도의 canonical digest(repo@sha256:...)다.
FROM public.ecr.aws/docker/library/nginx:stable-alpine@sha256:0985e772fb9f729e6fa0980da05fca5d9c468e870eed43071545afa9d2e27d94

# ── 빌드 시점 보안 패치 ───────────────────────────────────
# 2026-08 실증:
#   당시 선택한 공식 nginx:stable-alpine base image에서도 Trivy가
#   CVE-2026-14456(libcrypto3/libssl3, HIGH, fix available)을 탐지했다.
#
# 즉 "공식 이미지 + digest pin"은 artifact identity와 재현성을 개선할 뿐,
# 그 이미지에 알려진 취약점이 없다는 의미는 아니다.
#
# 대응 선택:
#   ✗ Trivy 기준을 CRITICAL로 낮춤 — 위험을 제거하지 않고 탐지만 약화
#   ✗ .trivyignore 추가             — 수정 가능한 취약점에는 부적절
#   ✓ apk upgrade로 사용 가능한 보안 패치를 반영하고 기존 게이트 유지
#
# ⚠ 재현성 트레이드오프:
#   base image 자체는 digest로 고정됐지만 apk upgrade는 빌드 시점의
#   Alpine repository 상태를 참조하므로 결과가 완전히 결정적이지는 않다.
#   최종 산출물은 ECR canonical digest로 식별하고,
#   Trivy → Inspector → Cosign → Kyverno가 동일 digest를 대상으로 검증한다.
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
