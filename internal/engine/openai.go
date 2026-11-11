package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"

	"github.com/Tetrix-Technologies/tetrix-host/internal/config"
)

// openAI fronts any server that speaks the OpenAI HTTP dialect: llama.cpp's
// llama-server, LM Studio, vLLM, mlx_lm.server, and others. Such a server
// manages its own models, so Pull and Delete are unsupported here.
type openAI struct {
	cfg    config.EngineConfig
	client *http.Client
}

func (o *openAI) Config() config.EngineConfig { return o.cfg }

func (o *openAI) Upstream(path string) string { return o.cfg.BaseURL + path }

func (o *openAI) Authorize(req *http.Request) {
	if o.cfg.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+o.cfg.APIKey)
	}
}

func (o *openAI) list(ctx context.Context) ([]string, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", o.cfg.BaseURL+"/v1/models", nil)
	if err != nil {
		return nil, err
	}
	o.Authorize(req)
	resp, err := o.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return nil, fmt.Errorf("the engine answered %d", resp.StatusCode)
	}
	var list struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(&list); err != nil {
		return nil, err
	}
	ids := make([]string, 0, len(list.Data))
	for _, m := range list.Data {
		ids = append(ids, m.ID)
	}
	return ids, nil
}

func (o *openAI) Probe(ctx context.Context) (string, error) {
	_, err := o.list(ctx)
	return "", err
}

func (o *openAI) Models(ctx context.Context) ([]Model, error) {
	ids, err := o.list(ctx)
	if err != nil {
		return nil, err
	}
	models := make([]Model, 0, len(ids))
	for _, id := range ids {
		// A server of this kind keeps its one model in memory.
		models = append(models, Model{ID: o.cfg.ID + "/" + id, Engine: o.cfg.ID, Name: id, Loaded: true})
	}
	return models, nil
}

func (o *openAI) Pull(context.Context, string, func(Progress)) error { return ErrUnsupported }

func (o *openAI) Delete(context.Context, string) error { return ErrUnsupported }
