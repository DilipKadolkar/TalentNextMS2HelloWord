# ---------- Stage 1: build the jar with Maven ----------
# Images are pulled from the ECR Public Gallery to avoid Docker Hub rate limits in CodeBuild.
FROM public.ecr.aws/docker/library/maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app

# Cache dependencies first so code-only changes rebuild faster
COPY pom.xml .
RUN mvn -B dependency:go-offline

COPY src ./src
RUN mvn -B clean package

# ---------- Stage 2: minimal runtime image ----------
FROM public.ecr.aws/docker/library/eclipse-temurin:21-jre
WORKDIR /app

RUN groupadd --system spring && useradd --system --gid spring spring
USER spring

COPY --from=build /app/target/hello-world-app.jar app.jar

EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
