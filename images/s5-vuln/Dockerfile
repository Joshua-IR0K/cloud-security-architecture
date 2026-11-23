# s5-vuln — S5 취약 이미지 (검증 축 ①)
# ⚠ 이 이미지는 절대 EKS 에 배포하지 않는다.
#   목적은 오직 "스캐너가 실제로 탐지하는가"를 실증하는 것이다.
#   푸시 → Inspector CRITICAL findings 확인 → 증거 캡처 까지가 수명.
#
# 왜 필요한가:
#   "스캔을 켰다"와 "스캔이 잡는다"는 다른 주장이다.
#   정상 이미지만 푸시하면 findings 0 이 나오는데, 그것이
#   "안전해서"인지 "스캐너가 동작하지 않아서"인지 구분할 수 없다.
#   → 대조군이 있어야 ②(정상 통과)가 의미를 갖는다. S2·S3·S4 의 BREAK 와 같은 역할.
#
# 취약성 확보 방법: 오래된 base image 를 그대로 사용한다.
#   임의로 취약 패키지를 설치하는 것보다 재현성이 높고,
#   "base image 를 방치하면 어떻게 되는가"라는 현실적 시나리오다.

# 의도적으로 낡은 태그 — 다수의 알려진 CVE 를 포함
FROM public.ecr.aws/docker/library/nginx:1.20-alpine

LABEL org.opencontainers.image.title="s5-vuln" \
      org.opencontainers.image.description="INTENTIONALLY VULNERABLE - scanner validation only. DO NOT DEPLOY." \
      security.deploy="forbidden"

EXPOSE 80
