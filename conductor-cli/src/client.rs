use anyhow::{Context, Result};
use reqwest::header::{HeaderMap, HeaderValue, AUTHORIZATION, CONTENT_TYPE, ACCEPT};
use serde_json::Value;

use crate::config::Config;

/// HTTP client wrapper that handles authentication and base URL resolution.
#[allow(dead_code)]
pub struct Client {
    http: reqwest::Client,
    base_url: String,
    token: String,
}

impl Client {
    /// Create a new API client from the saved configuration.
    pub fn new(config: &Config) -> Result<Self> {
        let base_url = config.require_url()?.trim_end_matches('/').to_string();
        let token = config.require_token()?.to_string();

        let mut default_headers = HeaderMap::new();
        default_headers.insert(
            AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {}", token))
                .context("Invalid token format")?,
        );
        default_headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
        default_headers.insert(ACCEPT, HeaderValue::from_static("application/json"));

        let http = reqwest::Client::builder()
            .default_headers(default_headers)
            .build()
            .context("Failed to create HTTP client")?;

        Ok(Self {
            http,
            base_url,
            token,
        })
    }

    /// Create a client for verification during login (before config is saved).
    pub fn new_with_credentials(url: &str, token: &str) -> Result<Self> {
        let base_url = url.trim_end_matches('/').to_string();

        let mut default_headers = HeaderMap::new();
        default_headers.insert(
            AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {}", token))
                .context("Invalid token format")?,
        );
        default_headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
        default_headers.insert(ACCEPT, HeaderValue::from_static("application/json"));

        let http = reqwest::Client::builder()
            .default_headers(default_headers)
            .build()
            .context("Failed to create HTTP client")?;

        Ok(Self {
            http,
            base_url,
            token: token.to_string(),
        })
    }

    /// Build the full URL for an API path.
    fn url(&self, path: &str) -> String {
        format!("{}{}", self.base_url, path)
    }

    /// Perform a GET request and return the parsed JSON response.
    pub async fn get(&self, path: &str) -> Result<Value> {
        let url = self.url(path);
        let response = self
            .http
            .get(&url)
            .send()
            .await
            .with_context(|| format!("Request failed: GET {}", url))?;

        let status = response.status();
        let body = response
            .text()
            .await
            .with_context(|| format!("Failed to read response body from GET {}", url))?;

        if !status.is_success() {
            let error_msg = serde_json::from_str::<Value>(&body)
                .ok()
                .and_then(|v| v.get("error").and_then(|e| e.as_str().map(String::from)))
                .unwrap_or_else(|| format!("HTTP {} - {}", status.as_u16(), body));
            anyhow::bail!("{}", error_msg);
        }

        serde_json::from_str(&body)
            .with_context(|| format!("Failed to parse JSON response from GET {}", url))
    }

    /// Perform a POST request with an optional JSON body.
    pub async fn post(&self, path: &str, body: Option<Value>) -> Result<Value> {
        let url = self.url(path);
        let mut request = self.http.post(&url);

        if let Some(json_body) = body {
            request = request.json(&json_body);
        }

        let response = request
            .send()
            .await
            .with_context(|| format!("Request failed: POST {}", url))?;

        let status = response.status();
        let response_body = response
            .text()
            .await
            .with_context(|| format!("Failed to read response body from POST {}", url))?;

        if !status.is_success() {
            let error_msg = serde_json::from_str::<Value>(&response_body)
                .ok()
                .and_then(|v| {
                    v.get("error")
                        .and_then(|e| e.as_str().map(String::from))
                        .or_else(|| {
                            v.get("errors").and_then(|e| {
                                e.as_array().map(|arr| {
                                    arr.iter()
                                        .filter_map(|v| v.as_str())
                                        .collect::<Vec<_>>()
                                        .join(", ")
                                })
                            })
                        })
                })
                .unwrap_or_else(|| format!("HTTP {} - {}", status.as_u16(), response_body));
            anyhow::bail!("{}", error_msg);
        }

        serde_json::from_str(&response_body)
            .with_context(|| format!("Failed to parse JSON response from POST {}", url))
    }

    /// Perform a DELETE request.
    #[allow(dead_code)]
    pub async fn delete(&self, path: &str) -> Result<Value> {
        let url = self.url(path);
        let response = self
            .http
            .delete(&url)
            .send()
            .await
            .with_context(|| format!("Request failed: DELETE {}", url))?;

        let status = response.status();
        let body = response
            .text()
            .await
            .with_context(|| format!("Failed to read response body from DELETE {}", url))?;

        if !status.is_success() {
            let error_msg = serde_json::from_str::<Value>(&body)
                .ok()
                .and_then(|v| v.get("error").and_then(|e| e.as_str().map(String::from)))
                .unwrap_or_else(|| format!("HTTP {} - {}", status.as_u16(), body));
            anyhow::bail!("{}", error_msg);
        }

        serde_json::from_str(&body)
            .with_context(|| format!("Failed to parse JSON response from DELETE {}", url))
    }

    /// Get the base URL (for display purposes).
    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// Get the token (for display purposes).
    #[allow(dead_code)]
    pub fn token(&self) -> &str {
        &self.token
    }
}
