import { View, div } from "gpui-kit";
import { checking, closeOverlay, focused, layout, nextCommand, props, setShared, shared, terminals } from "herdr";

// These inline controls in Herdr's built-in layouts open dialogs for text
// entry. The Changes panel and custom mods can take text input in place.
const paneChrome = new Set([
    "agents", "files", "pane", "spaces", "tabs", "terminals-bar",
    "terminals-pane", "workspace-chrome", "workspace-status",
]);
function mayTakeInput(content) {
    if (!content?.mod) return false;
    if (content.mod === "win98") {
        return !["desktop", "window", "clippy", "taskbar"].includes(content.props?.role);
    }
    return !paneChrome.has(content.mod);
}

// A floating terminal or agent block can take focus without changing the
// reported model pane or layout terminal. Require visible candidates to agree.
// Herdr treats a terminal's Find field as part of that same pane.
function terminalForRules(current, tree) {
    if (!current) return null;
    const reported = current.shown ?? current.terminal ?? null;
    let inBaseLayout = false;
    const candidates = new Set();
    const floats = new Set();
    if (!current.pane && reported) candidates.add(reported);
    function visit(node) {
        if (!node || node.hidden) return;
        if (node.content?.terminal === reported) inBaseLayout = true;
        if (node.content?.tab && current.pane) candidates.add(reported);
        if (node.content?.agent) candidates.add(current.agent ?? null);
        if (mayTakeInput(node.content) || mayTakeInput(node.header?.content) ||
            mayTakeInput(node.content?.pane?.header?.content)) {
            candidates.add(null);
        }
        for (const item of node.floating ?? []) {
            if (item.hidden) continue;
            if (item.content?.terminal) floats.add(item.content.terminal);
            if (mayTakeInput(item.content)) candidates.add(null);
        }
        const children = node.children ?? [];
        if (node.type === "stack") {
            visit(children.find(c => c.id === node.active && !c.hidden) ?? children.find(c => !c.hidden));
        } else {
            children.forEach(visit);
        }
    }
    visit(tree);
    if (candidates.size !== 1) return null;
    const [address] = candidates;
    if (!address || [...floats].some(terminal => terminal !== address)) return null;
    // A fixed terminal block can still be reported under an editable dialog.
    return { address, overlayTerminal: !current.pane && !inBaseLayout && !floats.has(address) };
}

export default class InputSourceFocus extends View {
    init(_props, cx) {
        const overlay = props()?.overlay;
        if (checking() || overlay !== "mod-input-source-pro") return;
        // A hot reload replaces this instance and stops its command loop.
        // Invalidate the old report so ISP subscribes to this copy.
        if (shared("input-source-pro.watch")) setShared("input-source-pro.watch", null);
        // ISP renews the watch every two seconds. If it exits before sending
        // overlay.close, release this copy, even if the first watch never arrived.
        const renew = cx => {
            this.expiry?.cancel();
            this.expiry = cx.timer.after(8000, () => closeOverlay(overlay));
        };
        renew(cx);
        cx.spawn(async cx => {
            for (;;) {
                const command = await nextCommand();
                const [kind, ...parts] = command.split("-");
                if (kind !== "watch" && kind !== "query") continue;
                const token = parts.join("-");
                if (kind === "watch") {
                    this.watch = token;
                    renew(cx);
                }
                this.publish(kind, token);
            }
        });
    }

    publish(kind, token) {
        const current = focused();
        const tree = layout();
        const target = terminalForRules(current, tree);
        const address = target?.address ?? null;
        const record = address && !address.includes("/")
            ? terminals().find(t => t.address === address && t.state === "live")
            : null;
        const focus = {
            pane: current?.pane ?? null,
            terminal: address,
            overlayTerminal: target?.overlayTerminal ?? false,
            pid: record?.pid ?? record?.foreground?.pid ?? null,
            toast: tree?.toast ?? null,
        };
        const value = { token, focus };
        if (kind === "watch") {
            const serialized = JSON.stringify(value);
            if (serialized === this.last) return;
            this.last = serialized;
        }
        setShared("input-source-pro." + kind, value);
    }

    render() {
        if (this.watch) this.publish("watch", this.watch);
        return div().w(0).h(0);
    }

    close() {
        if (this.watch && shared("input-source-pro.watch")?.token === this.watch) {
            setShared("input-source-pro.watch", null);
        }
    }
}
