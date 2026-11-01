FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags "-s -w" -o /out/onboarding-app .

FROM alpine:3.21
RUN apk add --no-cache ca-certificates && \
    addgroup -S app && adduser -S -G app app
COPY --from=build /out/onboarding-app /usr/local/bin/onboarding-app
USER app
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/onboarding-app"]
