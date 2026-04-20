"use client";

import { useCallback, useEffect, useRef, useState } from "react";

export interface StreamMessage {
  domain: string;
  topic: string;
  timestamp: number;
  data: unknown;
  // Set by the API when replaying buffered state on subscribe so the UI can
  // distinguish "recent snapshot" from "live". Absent on live messages.
  snapshot?: boolean;
}

interface ConnectedMessage {
  type: "connected";
  session_id: string;
}

interface SubscribedMessage {
  type: "subscribed" | "unsubscribed";
  topics: string[];
}

interface ErrorMessage {
  type: "error";
  message: string;
}

type ServerMessage = ConnectedMessage | SubscribedMessage | ErrorMessage | StreamMessage;

function isControlMessage(msg: unknown): msg is ConnectedMessage | SubscribedMessage | ErrorMessage {
  return typeof msg === "object" && msg !== null && "type" in msg;
}

// NEXT_PUBLIC_API_HOST is inlined at build time. Accept either a bare
// host (`api.metrovelox.com`, optionally with port) or a full URL
// (`https://api.metrovelox.com`) so operators can configure it either
// way without guessing what the frontend wants.
//
// When unset (the common case in prod, where the image is built before
// DNS is finalised), we fall back to `api.<page-host>` for any non-local
// origin. That keeps us HTTPS-aware — the scheme is always derived from
// the page so the browser never blocks us with a mixed-content error.
function resolveWsUrl(): string | null {
  if (typeof window === "undefined") return null;

  const pageProtoWs =
    window.location.protocol === "https:" ? "wss:" : "ws:";
  const envHost = process.env.NEXT_PUBLIC_API_HOST;

  if (envHost) {
    try {
      const raw =
        envHost.startsWith("http") || envHost.startsWith("ws")
          ? envHost
          : `${window.location.protocol}//${envHost}`;
      const u = new URL(raw);
      const proto =
        u.protocol === "https:" || u.protocol === "wss:" ? "wss:" : "ws:";
      return `${proto}//${u.host}/ws/streams`;
    } catch {
      // fall through to heuristic default
    }
  }

  const host = window.location.host;
  const isLocal = /^(localhost|127\.|0\.0\.0\.0)/.test(host);
  const apiHost = isLocal || host.startsWith("api.") ? host : `api.${host}`;
  return `${pageProtoWs}//${apiHost}/ws/streams`;
}

const RECONNECT_BASE_MS = 1000;
const RECONNECT_MAX_MS = 30_000;

/**
 * React hook that manages a WebSocket connection to the OpenVelox streaming
 * gateway.  Subscribes to the requested Kafka topics and calls `onMessage`
 * for every data envelope received.
 *
 * Returns connection status and a message counter for UI indicators.
 */
export function useStreams(
  topics: string[],
  onMessage: (msg: StreamMessage) => void,
) {
  const [status, setStatus] = useState<"connecting" | "connected" | "disconnected">(
    "disconnected",
  );
  const [messageCount, setMessageCount] = useState(0);
  const [snapshotCount, setSnapshotCount] = useState(0);
  const [sessionId, setSessionId] = useState<string | null>(null);

  const wsRef = useRef<WebSocket | null>(null);
  const topicsRef = useRef<string[]>(topics);
  const prevTopicsRef = useRef<Set<string>>(new Set());
  const onMessageRef = useRef(onMessage);
  const retriesRef = useRef(0);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  onMessageRef.current = onMessage;
  topicsRef.current = topics;

  const sendCommand = useCallback(
    (action: "subscribe" | "unsubscribe", t: string[]) => {
      const ws = wsRef.current;
      if (ws?.readyState === WebSocket.OPEN && t.length > 0) {
        ws.send(JSON.stringify({ action, topics: t }));
      }
    },
    [],
  );

  const connect = useCallback(() => {
    const url = resolveWsUrl();
    if (!url) return;

    setStatus("connecting");
    const ws = new WebSocket(url);
    wsRef.current = ws;

    ws.onopen = () => {
      retriesRef.current = 0;
      setStatus("connected");
      if (topicsRef.current.length > 0) {
        sendCommand("subscribe", topicsRef.current);
        prevTopicsRef.current = new Set(topicsRef.current);
      }
    };

    ws.onmessage = (event) => {
      let parsed: ServerMessage;
      try {
        parsed = JSON.parse(event.data) as ServerMessage;
      } catch {
        return;
      }

      if (isControlMessage(parsed)) {
        if (parsed.type === "connected") {
          setSessionId(parsed.session_id);
        }
        return;
      }

      const stream = parsed as StreamMessage;
      if (stream.snapshot) {
        setSnapshotCount((c) => c + 1);
      } else {
        setMessageCount((c) => c + 1);
      }
      onMessageRef.current(stream);
    };

    ws.onclose = () => {
      setStatus("disconnected");
      setSessionId(null);
      prevTopicsRef.current = new Set();
      const delay = Math.min(
        RECONNECT_BASE_MS * 2 ** retriesRef.current,
        RECONNECT_MAX_MS,
      );
      retriesRef.current += 1;
      timerRef.current = setTimeout(connect, delay);
    };

    ws.onerror = () => {
      ws.close();
    };
  }, [sendCommand]);

  // Initial connection + cleanup
  useEffect(() => {
    connect();
    return () => {
      if (timerRef.current) clearTimeout(timerRef.current);
      wsRef.current?.close();
    };
  }, [connect]);

  // Reset counters across reconnects so the UI reflects what the *current*
  // session has delivered, not a running total across flaps. Keyed on
  // `sessionId` which changes every time the server emits a new one.
  useEffect(() => {
    if (sessionId) {
      setMessageCount(0);
      setSnapshotCount(0);
    }
  }, [sessionId]);

  // Handle topic list changes (incremental diff)
  useEffect(() => {
    const next = new Set(topics);
    const prev = prevTopicsRef.current;

    const toSubscribe = topics.filter((t) => !prev.has(t));
    const toUnsubscribe = [...prev].filter((t) => !next.has(t));

    if (toSubscribe.length > 0) sendCommand("subscribe", toSubscribe);
    if (toUnsubscribe.length > 0) sendCommand("unsubscribe", toUnsubscribe);

    prevTopicsRef.current = next;
  }, [topics, sendCommand]);

  return { status, messageCount, snapshotCount, sessionId };
}
