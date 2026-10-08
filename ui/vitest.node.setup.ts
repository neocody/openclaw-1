import { beforeEach, vi } from "vitest";

const values = new Map<string, string>();
vi.stubGlobal("localStorage", {
  getItem: (key: string) => values.get(key) ?? null,
  setItem: (key: string, value: string) => values.set(key, String(value)),
  removeItem: (key: string) => values.delete(key),
  clear: () => values.clear(),
});
vi.stubGlobal("navigator", { language: "en-US" });
vi.stubGlobal(
  "window",
  Object.assign(new EventTarget(), {
    setTimeout,
    clearTimeout,
  }),
);
beforeEach(() => values.clear());
