package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	if len(os.Args) == 2 && os.Args[1] == "healthcheck" {
		if err := runHealthcheck(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if len(os.Args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: controller [healthcheck]")
		os.Exit(2)
	}

	cfg, err := ConfigFromEnv()
	if err != nil {
		log.Fatalf("configuration error: %v", err)
	}
	store, err := NewStore(cfg.DataDir)
	if err != nil {
		log.Fatalf("persistent store error: %v", err)
	}
	app := NewApp(cfg, store)
	server := &http.Server{
		Addr: cfg.ListenAddress, Handler: app,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-stop
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(ctx); err != nil {
			log.Printf("graceful shutdown failed: %v", err)
		}
	}()

	log.Printf("controller listening on %s (runtime_mode=%s, lifecycle_scope=lease_registry_only)", cfg.ListenAddress, cfg.RuntimeMode)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("server failed: %v", err)
	}
}

func runHealthcheck() error {
	endpoint := envString("HEALTHCHECK_URL", "http://127.0.0.1:8080/healthz")
	client := &http.Client{Timeout: 2 * time.Second}
	request, err := http.NewRequest(http.MethodGet, endpoint, nil)
	if err != nil {
		return fmt.Errorf("create health request: %w", err)
	}
	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("health request failed: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("health endpoint returned HTTP %d", response.StatusCode)
	}
	return nil
}
