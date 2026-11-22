package main

import (
	"context"
	"crypto/rand"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"cloud.google.com/go/spanner"
	"google.golang.org/api/iterator"
)

//go:embed web/index.html
var webFS embed.FS

type Todo struct {
	ID        string    `json:"id"`
	Title     string    `json:"title"`
	Done      bool      `json:"done"`
	CreatedAt time.Time `json:"created_at"`
}

type server struct {
	db *spanner.Client
}

func newID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

func main() {
	dbName := os.Getenv("SPANNER_DATABASE")
	if dbName == "" {
		log.Fatal("SPANNER_DATABASE is required")
	}
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// SPANNER_EMULATOR_HOST が設定されていれば、クライアントライブラリが自動でエミュレータへ接続する。
	client, err := spanner.NewClient(ctx, dbName)
	if err != nil {
		log.Fatalf("spanner client: %v", err)
	}
	defer client.Close()

	s := &server{db: client}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("GET /readyz", s.readyz)
	mux.HandleFunc("GET /api/todos", s.list)
	mux.HandleFunc("POST /api/todos", s.create)
	mux.HandleFunc("PATCH /api/todos/{id}", s.update)
	mux.HandleFunc("DELETE /api/todos/{id}", s.delete)
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		b, _ := webFS.ReadFile("web/index.html")
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(b)
	})

	srv := &http.Server{Addr: ":" + port, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		srv.Shutdown(shutdownCtx)
	}()

	log.Printf("listening on :%s", port)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func (s *server) readyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	iter := s.db.Single().Query(ctx, spanner.NewStatement("SELECT 1"))
	defer iter.Stop()
	if _, err := iter.Next(); err != nil {
		http.Error(w, "spanner not ready", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusOK)
}

func (s *server) list(w http.ResponseWriter, r *http.Request) {
	iter := s.db.Single().Query(r.Context(), spanner.NewStatement(
		"SELECT id, title, done, created_at FROM todos ORDER BY created_at"))
	defer iter.Stop()

	todos := []Todo{}
	for {
		row, err := iter.Next()
		if err == iterator.Done {
			break
		}
		if err != nil {
			serverError(w, err)
			return
		}
		var t Todo
		if err := row.Columns(&t.ID, &t.Title, &t.Done, &t.CreatedAt); err != nil {
			serverError(w, err)
			return
		}
		todos = append(todos, t)
	}
	writeJSON(w, http.StatusOK, todos)
}

func (s *server) create(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Title string `json:"title"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&in); err != nil || in.Title == "" || len(in.Title) > 200 {
		http.Error(w, "invalid title", http.StatusBadRequest)
		return
	}
	id := newID()
	_, err := s.db.Apply(r.Context(), []*spanner.Mutation{
		spanner.Insert("todos", []string{"id", "title", "done", "created_at"},
			[]any{id, in.Title, false, spanner.CommitTimestamp}),
	})
	if err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

func (s *server) update(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Done bool `json:"done"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&in); err != nil {
		http.Error(w, "invalid body", http.StatusBadRequest)
		return
	}
	id := r.PathValue("id")
	var n int64
	_, err := s.db.ReadWriteTransaction(r.Context(), func(ctx context.Context, tx *spanner.ReadWriteTransaction) error {
		var err error
		n, err = tx.Update(ctx, spanner.Statement{
			SQL:    "UPDATE todos SET done = @done WHERE id = @id",
			Params: map[string]any{"done": in.Done, "id": id},
		})
		return err
	})
	if err != nil {
		serverError(w, err)
		return
	}
	if n == 0 {
		http.NotFound(w, r)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) delete(w http.ResponseWriter, r *http.Request) {
	// Mutation の Delete は存在しない行でもエラーにならないため、冪等な削除として 204 を返す。
	_, err := s.db.Apply(r.Context(), []*spanner.Mutation{
		spanner.Delete("todos", spanner.Key{r.PathValue("id")}),
	})
	if err != nil {
		serverError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func serverError(w http.ResponseWriter, err error) {
	log.Printf("error: %v", err)
	http.Error(w, "internal error", http.StatusInternalServerError)
}
