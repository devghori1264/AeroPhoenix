package main

import (
	"log"
	"net/http"
)

//nolint:unused
func startHTTP() {
	http.HandleFunc("/ping", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("pong from flyd-sim http"))
	})
	log.Println("flyd-sim HTTP server on :8080")
	http.ListenAndServe(":8080", nil)
}
