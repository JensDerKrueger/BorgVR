export function renderDatasetProvenance(container, entries) {
  container.replaceChildren();
  const list = container.ownerDocument.createElement("ol");
  list.className = "provenance-list";
  const formatter = new Intl.DateTimeFormat(undefined, {
    year: "numeric", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit", timeZoneName: "short"
  });
  for (const entry of Array.isArray(entries) ? entries : []) {
    if (!entry || typeof entry.text !== "string") continue;
    const item = container.ownerDocument.createElement("li");
    const time = container.ownerDocument.createElement("time");
    const date = new Date(entry.timestampMilliseconds);
    if (typeof entry.timestampMilliseconds === "number" && Number.isFinite(date.getTime())) {
      time.dateTime = date.toISOString();
      time.textContent = formatter.format(date);
      time.title = date.toISOString();
    } else { time.textContent = "Date unavailable"; }
    const text = container.ownerDocument.createElement("span");
    text.textContent = entry.text;
    item.append(time, text);
    list.append(item);
  }
  if (list.children.length) container.append(list);
  else container.textContent = "No provenance recorded.";
}
