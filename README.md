# hello-world-app: Spring Boot on AWS ECS (Fargate)

A small Spring Boot 3 (Java 21) Hello World REST API. It is containerised with Docker and deployed to **Amazon ECS on Fargate** through a CI/CD pipeline built from **AWS CodeCommit → AWS CodeBuild → Amazon ECR → AWS CodeDeploy (blue/green) → Amazon ECS**, run by **AWS CodePipeline**.

```
 git push           Source             Build                         Deploy
 ────────►  CodeCommit  ──►  CodeBuild (buildspec.yaml)  ──►  CodeDeploy blue/green  ──►  ECS Fargate service
            hello-world-app   docker build + push ──► ECR      (appspec.yaml + taskdef.json)   behind an ALB
```

---

## 1. Project layout

| File | Purpose |
|---|---|
| `pom.xml` | Maven build (Spring Boot 3.3.4, Java 21). Produces `target/hello-world-app.jar` |
| `src/main/java/.../HelloWorldController.java` | REST controller |
| `src/main/resources/application.properties` | Port `8080`, exposes `/actuator/health` |
| `Dockerfile` | Multi-stage build: Maven builds and tests the jar, then a slim JRE image runs it |
| `buildspec.yaml` | CodeBuild steps: build the image, push it to ECR, write the deploy artifacts |
| `appspec.yaml` | CodeDeploy AppSpec for the ECS blue/green deployment |
| `taskdef.json` | ECS task definition template used by the pipeline |

### Endpoints

| Method | Path | Response |
|---|---|---|
| GET | `/` | `Hello World from Spring Boot on AWS ECS!` |
| GET | `/api/hello?name=AWS` | `{"message":"Hello, AWS!"}` |
| GET | `/actuator/health` | `{"status":"UP"}` (used by the load balancer health check) |

---

## 2. Run locally

```bash
mvn spring-boot:run
curl http://localhost:8080/
curl "http://localhost:8080/api/hello?name=AWS"
```

With Docker:

```bash
docker build -t hello-world-app .
docker run -p 8080:8080 hello-world-app
```

---

## 3. AWS resource names used in this guide

| Resource | Name |
|---|---|
| CodeCommit repository | `hello-world-app` |
| ECR repository | `hello-world-app` |
| ECS cluster | `hello-world-cluster` |
| ECS task definition (family) | `hello-world-task` |
| Container name | `hello-world-container` (port `8080`) |
| ECS service | `hello-world-service` |
| CloudWatch log group | `/ecs/hello-world-task` |
| Application Load Balancer | `hello-world-alb` |
| Target groups | `hello-world-tg-blue`, `hello-world-tg-green` |
| ALB listeners | `80` (production), `8080` (test traffic) |
| Security groups | `hello-world-alb-sg`, `hello-world-ecs-sg` |
| CodeBuild project | `hello-world-build` |
| CodeDeploy application | `hello-world-codedeploy-app` |
| CodeDeploy deployment group | `hello-world-deployment-group` |
| CodePipeline | `hello-world-pipeline` |
| IAM roles | `ecsTaskExecutionRole`, `ecsCodeDeployRole` |

> The container name `hello-world-container` and port `8080` appear in `taskdef.json`, `appspec.yaml` and `buildspec.yaml`. If you rename them, change all three files.

---

## 4. Prerequisites

- An AWS account and an IAM user or role with admin rights (or rights for the services above).
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), configured with `aws configure`.
- Git, plus either:
  - HTTPS Git credentials for CodeCommit (IAM → Users → *your user* → Security credentials → **HTTPS Git credentials for AWS CodeCommit** → Generate), or
  - `pip install git-remote-codecommit` (uses your AWS CLI credentials directly).
- Docker, for the first manual image push (step 6).

Set some shell variables used by the commands below (change the region to suit):

```bash
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR_URI=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/hello-world-app
```

All steps can also be done in the AWS Console. The console path is given with each step.

---

## 5. Push the code to CodeCommit

Console: **CodeCommit → Repositories → Create repository** → name `hello-world-app`.

```bash
aws codecommit create-repository --repository-name hello-world-app \
  --repository-description "Spring Boot Hello World deployed to ECS" --region $AWS_REGION

# From the folder that contains pom.xml, buildspec.yaml, appspec.yaml ... (e.g. the unzipped hello-world-app.zip)
cd hello-world-app
git init -b main
git add .
git commit -m "Initial commit: Spring Boot Hello World for ECS"

# Option A: HTTPS Git credentials
git remote add origin https://git-codecommit.$AWS_REGION.amazonaws.com/v1/repos/hello-world-app
# Option B: git-remote-codecommit
# git remote add origin codecommit::$AWS_REGION://hello-world-app

git push -u origin main
```

> `buildspec.yaml`, `appspec.yaml`, `taskdef.json` and `Dockerfile` must be at the **root** of the repository.

---

## 6. Create the ECR repository and push the first image

The ECS service in step 9 needs an image to start with. Later images are pushed by CodeBuild.

Console: **ECR → Private registry → Repositories → Create repository** → name `hello-world-app`.

```bash
aws ecr create-repository --repository-name hello-world-app \
  --image-scanning-configuration scanOnPush=true --region $AWS_REGION

aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

docker build -t $ECR_URI:latest .
docker push $ECR_URI:latest
```

> On an Apple Silicon (ARM) Mac, build with `docker build --platform linux/amd64 ...`, because Fargate runs x86_64 by default.

---

## 7. IAM roles

### 7.1 ECS task execution role: `ecsTaskExecutionRole`

This role lets ECS pull the image from ECR and write logs to CloudWatch. Many accounts already have it; check under **IAM → Roles**. To create it:

```bash
cat > ecs-tasks-trust.json <<'EOF'
{ "Version": "2012-10-17",
  "Statement": [{ "Effect": "Allow",
                  "Principal": { "Service": "ecs-tasks.amazonaws.com" },
                  "Action": "sts:AssumeRole" }] }
EOF
aws iam create-role --role-name ecsTaskExecutionRole \
  --assume-role-policy-document file://ecs-tasks-trust.json
aws iam attach-role-policy --role-name ecsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
```

### 7.2 CodeDeploy role for ECS: `ecsCodeDeployRole`

Console: **IAM → Roles → Create role → AWS service → CodeDeploy → use case "CodeDeploy - ECS"** → name `ecsCodeDeployRole`.

```bash
cat > codedeploy-trust.json <<'EOF'
{ "Version": "2012-10-17",
  "Statement": [{ "Effect": "Allow",
                  "Principal": { "Service": "codedeploy.amazonaws.com" },
                  "Action": "sts:AssumeRole" }] }
EOF
aws iam create-role --role-name ecsCodeDeployRole \
  --assume-role-policy-document file://codedeploy-trust.json
aws iam attach-role-policy --role-name ecsCodeDeployRole \
  --policy-arn arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS
```

The CodeBuild and CodePipeline service roles are created by the console in steps 11 and 12.

---

## 8. Networking: security groups, load balancer and target groups

This guide uses the **default VPC** and two of its public subnets.

```bash
export VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)
export SUBNET_1=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID \
  --query 'Subnets[0].SubnetId' --output text)
export SUBNET_2=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID \
  --query 'Subnets[1].SubnetId' --output text)

# ALB security group: allow 80 (production) and 8080 (test listener) from the internet
export ALB_SG=$(aws ec2 create-security-group --group-name hello-world-alb-sg \
  --description "hello-world ALB" --vpc-id $VPC_ID --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id $ALB_SG --protocol tcp --port 80   --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $ALB_SG --protocol tcp --port 8080 --cidr 0.0.0.0/0

# ECS tasks security group: allow 8080 only from the ALB
export ECS_SG=$(aws ec2 create-security-group --group-name hello-world-ecs-sg \
  --description "hello-world ECS tasks" --vpc-id $VPC_ID --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id $ECS_SG --protocol tcp --port 8080 \
  --source-group $ALB_SG

# Application Load Balancer
export ALB_ARN=$(aws elbv2 create-load-balancer --name hello-world-alb \
  --subnets $SUBNET_1 $SUBNET_2 --security-groups $ALB_SG \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

# Two target groups (blue and green). Target type "ip" is required for Fargate.
for COLOR in blue green; do
  aws elbv2 create-target-group --name hello-world-tg-$COLOR \
    --protocol HTTP --port 8080 --vpc-id $VPC_ID --target-type ip \
    --health-check-path /actuator/health
done
export TG_BLUE_ARN=$(aws elbv2 describe-target-groups --names hello-world-tg-blue \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
export TG_GREEN_ARN=$(aws elbv2 describe-target-groups --names hello-world-tg-green \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# Production listener (80) and test listener (8080). Both start pointing at blue.
export PROD_LISTENER_ARN=$(aws elbv2 create-listener --load-balancer-arn $ALB_ARN \
  --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=$TG_BLUE_ARN \
  --query 'Listeners[0].ListenerArn' --output text)
export TEST_LISTENER_ARN=$(aws elbv2 create-listener --load-balancer-arn $ALB_ARN \
  --protocol HTTP --port 8080 --default-actions Type=forward,TargetGroupArn=$TG_BLUE_ARN \
  --query 'Listeners[0].ListenerArn' --output text)
```

Console equivalent: **EC2 → Security Groups**, **EC2 → Target Groups** (type *IP addresses*, HTTP 8080, health check `/actuator/health`), **EC2 → Load Balancers → Create Application Load Balancer** (internet-facing, listeners 80 and 8080 → `hello-world-tg-blue`).

---

## 9. ECS cluster, task definition and service

```bash
# Cluster
aws ecs create-cluster --cluster-name hello-world-cluster

# Log group referenced by taskdef.json
aws logs create-log-group --log-group-name /ecs/hello-world-task

# Register the first task definition from the template, filling in the placeholders
sed -e "s|<AWS_ACCOUNT_ID>|$AWS_ACCOUNT_ID|g" \
    -e "s|<AWS_REGION>|$AWS_REGION|g" \
    -e "s|<IMAGE1_NAME>|$ECR_URI:latest|g" taskdef.json > taskdef-initial.json
aws ecs register-task-definition --cli-input-json file://taskdef-initial.json

# Service using the CODE_DEPLOY (blue/green) deployment controller
aws ecs create-service \
  --cluster hello-world-cluster \
  --service-name hello-world-service \
  --task-definition hello-world-task \
  --desired-count 1 \
  --launch-type FARGATE \
  --deployment-controller type=CODE_DEPLOY \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_1,$SUBNET_2],securityGroups=[$ECS_SG],assignPublicIp=ENABLED}" \
  --load-balancers targetGroupArn=$TG_BLUE_ARN,containerName=hello-world-container,containerPort=8080
```

> `assignPublicIp=ENABLED` lets the task pull the image from ECR in a public subnet that has no NAT gateway.

Console equivalent: **ECS → Clusters → Create cluster** (Fargate). **Task definitions → Create new task definition with JSON** (paste `taskdef-initial.json`). **Cluster → Services → Create**: launch type Fargate, family `hello-world-task`, service name `hello-world-service`, desired tasks 1, **Deployment options → Blue/green deployment (powered by AWS CodeDeploy)**, service role `ecsCodeDeployRole`, networking = default VPC and `hello-world-ecs-sg`, load balancer `hello-world-alb` with listener 80, test listener 8080, target groups blue and green. If you create the service in the console this way, the console also creates the CodeDeploy application and deployment group, so you can skip step 10 and use the names it generated in step 12.

Check that the app is reachable through the ALB:

```bash
export ALB_DNS=$(aws elbv2 describe-load-balancers --names hello-world-alb \
  --query 'LoadBalancers[0].DNSName' --output text)
curl http://$ALB_DNS/
```

---

## 10. CodeDeploy application and deployment group

Console: **CodeDeploy → Applications → Create application** → name `hello-world-codedeploy-app`, platform **Amazon ECS**. Then **Create deployment group** → `hello-world-deployment-group`, service role `ecsCodeDeployRole`, cluster `hello-world-cluster`, service `hello-world-service`, load balancer `hello-world-alb`, production listener `HTTP:80`, test listener `HTTP:8080`, target groups `hello-world-tg-blue` / `hello-world-tg-green`, traffic rerouting *immediately*, terminate original tasks after 5 minutes.

CLI:

```bash
aws deploy create-application --application-name hello-world-codedeploy-app \
  --compute-platform ECS

cat > deployment-group.json <<EOF
{
  "applicationName": "hello-world-codedeploy-app",
  "deploymentGroupName": "hello-world-deployment-group",
  "serviceRoleArn": "arn:aws:iam::$AWS_ACCOUNT_ID:role/ecsCodeDeployRole",
  "deploymentConfigName": "CodeDeployDefault.ECSAllAtOnce",
  "deploymentStyle": { "deploymentType": "BLUE_GREEN", "deploymentOption": "WITH_TRAFFIC_CONTROL" },
  "blueGreenDeploymentConfiguration": {
    "deploymentReadyOption": { "actionOnTimeout": "CONTINUE_DEPLOYMENT", "waitTimeInMinutes": 0 },
    "terminateBlueInstancesOnDeploymentSuccess": { "action": "TERMINATE", "terminationWaitTimeInMinutes": 5 }
  },
  "autoRollbackConfiguration": { "enabled": true, "events": ["DEPLOYMENT_FAILURE"] },
  "ecsServices": [{ "clusterName": "hello-world-cluster", "serviceName": "hello-world-service" }],
  "loadBalancerInfo": {
    "targetGroupPairInfoList": [{
      "targetGroups": [{ "name": "hello-world-tg-blue" }, { "name": "hello-world-tg-green" }],
      "prodTrafficRoute": { "listenerArns": ["$PROD_LISTENER_ARN"] },
      "testTrafficRoute": { "listenerArns": ["$TEST_LISTENER_ARN"] }
    }]
  }
}
EOF
aws deploy create-deployment-group --cli-input-json file://deployment-group.json
```

---

## 11. CodeBuild project: `hello-world-build`

Console: **CodeBuild → Build projects → Create build project**

| Setting | Value |
|---|---|
| Project name | `hello-world-build` |
| Source provider | AWS CodeCommit, repository `hello-world-app`, branch `main` |
| Environment | Managed image, **Amazon Linux**, runtime *Standard*, image `aws/codebuild/amazonlinux-x86_64-standard:5.0` (or the latest) |
| **Privileged** | **Enabled** (required to run `docker build`) |
| Service role | New service role (e.g. `codebuild-hello-world-build-service-role`) |
| Buildspec | *Use a buildspec file*, buildspec name **`buildspec.yaml`** |
| Artifacts | No artifacts (CodePipeline handles them) |
| Logs | CloudWatch logs enabled |

> CodeBuild looks for `buildspec.yml` by default. This project uses **`buildspec.yaml`**, so enter that name explicitly.

Give the CodeBuild role permission to push to ECR:

```bash
aws iam attach-role-policy --role-name codebuild-hello-world-build-service-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
```

What `buildspec.yaml` does:

1. Logs in to ECR and works out the image tag from the commit id.
2. Runs `docker build`. The Maven build and unit tests run inside the multi-stage Dockerfile.
3. Pushes `hello-world-app:latest` and `hello-world-app:<commit>` to ECR.
4. Writes `imageDetail.json` (the image URI for CodeDeploy blue/green) and `imagedefinitions.json` (for the rolling-update alternative in section 14).
5. Fills `<AWS_ACCOUNT_ID>` and `<AWS_REGION>` into `taskdef.json`.
6. Outputs `appspec.yaml`, `taskdef.json`, `imageDetail.json` and `imagedefinitions.json` as the build artifact.

---

## 12. CodePipeline: `hello-world-pipeline`

Console: **CodePipeline → Pipelines → Create pipeline → Build custom pipeline**

1. **Pipeline settings**: name `hello-world-pipeline`, type V2, execution mode *Queued* or *Superseded*, **New service role**.
2. **Source stage**: provider **AWS CodeCommit**, repository `hello-world-app`, branch `main`, change detection **Amazon CloudWatch Events** (recommended), output artifact format *CodePipeline default*. Output artifact: `SourceArtifact`.
3. **Build stage**: provider **AWS CodeBuild**, project `hello-world-build`. Output artifact: `BuildArtifact`.
4. **Deploy stage**: provider **Amazon ECS (Blue/Green)**
   - AWS CodeDeploy application name: `hello-world-codedeploy-app`
   - AWS CodeDeploy deployment group: `hello-world-deployment-group`
   - Amazon ECS task definition: `BuildArtifact`, file `taskdef.json`
   - AWS CodeDeploy AppSpec file: `BuildArtifact`, file `appspec.yaml`
   - Dynamically update task definition image: input artifact `BuildArtifact`, placeholder text **`IMAGE1_NAME`**
5. **Create pipeline**. The first run starts straight away.

How the deploy works: CodePipeline reads the image URI from `imageDetail.json`, puts it in place of `<IMAGE1_NAME>` in `taskdef.json`, and registers a new task definition revision. It then puts that revision's ARN in place of `<TASK_DEFINITION>` in `appspec.yaml` and starts a CodeDeploy blue/green deployment. CodeDeploy starts the new tasks in the green target group, moves the port 80 listener over to green, and stops the old tasks after 5 minutes.

---

## 13. Verify and release changes

```bash
curl http://$ALB_DNS/
curl "http://$ALB_DNS/api/hello?name=AWS"
curl http://$ALB_DNS/actuator/health
```

To release a change, edit the message in `HelloWorldController.java`, then:

```bash
git commit -am "Change greeting"
git push origin main
```

The pipeline runs Source → Build → Deploy. Watch it in **CodePipeline → hello-world-pipeline**, follow the traffic shift in **CodeDeploy → Deployments**, and refresh `http://<ALB_DNS>/`.

---

## 14. Alternative: rolling update without CodeDeploy

If you don't need blue/green:

- Create the ECS service with the default **Rolling update** deployment controller (one target group and a port 80 listener are enough).
- Skip step 10 (CodeDeploy).
- In the pipeline Deploy stage choose **Amazon ECS** as the provider: cluster `hello-world-cluster`, service `hello-world-service`, image definitions file `imagedefinitions.json`.

`buildspec.yaml` already writes `imagedefinitions.json`, so no file changes are needed. `appspec.yaml` is only used by the blue/green deployment.

---

## 15. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| CodeBuild: `Cannot connect to the Docker daemon` | **Privileged** mode is not enabled on the CodeBuild environment |
| CodeBuild: `YAML_FILE_ERROR ... buildspec.yml` | Set the buildspec name to `buildspec.yaml` in the project settings |
| CodeBuild: `denied: User ... not authorized to perform ecr:...` | Attach `AmazonEC2ContainerRegistryPowerUser` to the CodeBuild service role |
| CodeBuild: `toomanyrequests` from Docker Hub | The Dockerfile already uses `public.ecr.aws` images; keep it that way |
| ECS task stops with `CannotPullContainerError` | The task has no route to ECR: use `assignPublicIp=ENABLED` in a public subnet, or add a NAT gateway or VPC endpoints |
| Targets `unhealthy` in the target group | `hello-world-ecs-sg` must allow 8080 from `hello-world-alb-sg`; the health check path must be `/actuator/health` |
| Deploy stage: `iam:PassRole` error | The CodePipeline service role needs `iam:PassRole` on `ecsTaskExecutionRole` |
| CodeDeploy: `The ECS service cannot be found` / wrong controller | The ECS service must be created with `--deployment-controller type=CODE_DEPLOY` |

---

## 16. Clean up (avoid charges)

```bash
aws codepipeline delete-pipeline --name hello-world-pipeline
aws codebuild delete-project --name hello-world-build
aws deploy delete-application --application-name hello-world-codedeploy-app
aws ecs update-service --cluster hello-world-cluster --service hello-world-service --desired-count 0
aws ecs delete-service --cluster hello-world-cluster --service hello-world-service --force
aws ecs delete-cluster --cluster hello-world-cluster
aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN
# wait about a minute for the ALB to be deleted, then:
aws elbv2 delete-target-group --target-group-arn $TG_BLUE_ARN
aws elbv2 delete-target-group --target-group-arn $TG_GREEN_ARN
aws ec2 delete-security-group --group-id $ECS_SG
aws ec2 delete-security-group --group-id $ALB_SG
aws ecr delete-repository --repository-name hello-world-app --force
aws codecommit delete-repository --repository-name hello-world-app
aws logs delete-log-group --log-group-name /ecs/hello-world-task
```

Also delete the S3 bucket CodePipeline created for its artifacts (`codepipeline-<region>-...`) if you no longer need it.
