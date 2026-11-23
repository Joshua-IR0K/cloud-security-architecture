terraform {
  # ~> 1.14.0으로 패치만 허용한다. 하한만 두면 로컬이 CI보다 먼저 올라갈 수 있고, 높은 버전이 쓴 state는 낮은 버전이 못 읽어서 CI plan이 깨진다.
  # 올릴 때는 CI부터 올린다. 기술적으로 최소 요건은 write-only 인자가 생긴 1.11이다.
  required_version = "~> 1.14.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # >= 6.50: Secrets Manager write-only 인자 관련 수정 포함
      version = ">= 6.50, < 7.0"
    }
    # ephemeral "random_password". 값이 state에 남지 않는 생성기
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
