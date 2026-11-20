import { View, div } from "gpui-kit";
import { checking, focused, layout, nextCommand, props, setShared, shared, terminals } from "herdr";

// Herdr 0.1.16 keeps focused().terminal on the model pane when a floating
// terminal or an agent block takes the keyboard. If these surfaces disagree,
// there is no public keyboard owner to use for a rule or a writer command.
function keyboardTerminal(current) {
    if (!current) return null;
    const candidates = new Set();
    const floats = new Set();
    const reported = current.shown ?? current.terminal ?? null;
    // A focused layout terminal or a terminal in an overlay (including peek)
    // is reported directly, with no model pane.
    if (!current.pane && reported) return reported;
    const candidates = new Set();
    function visit(node) {
        if (!node || node.hidden) return;
        if (node.content?.tab && current.pane) candidates.add(reported);
        if (node.content?.agent) candidates.add(current.agent ?? null);
        for (const item of node.floating ?? []) {
            if (!item.hidden && item.content?.terminal) floats.add(item.content.terminal);
        }
        const children = node.children ?? [];
        if (node.type === "stack") {
            visit(children.find(c => c.id === node.active && !c.hidden) ?? children.find(c => !c.hidden));
        } else {
            children.forEach(visit);
        }
    }
    visit(layout());
    if (candidates.size !== 1) return null;
    const [address] = candidates;
    return [...floats].every(terminal => terminal === address) ? address : null;
}

export default class InputSourceFocus extends View {
    init(_props, cx) {
        if (checking() || props()?.overlay !== "mod-input-source-pro") return;
        // A hot reload replaces this instance and stops its command loop.
        // Invalidate the old report so ISP subscribes to this copy.
        if (shared("input-source-pro.watch")) setShared("input-source-pro.watch", null);
        cx.spawn(async () => {
            for (;;) {
                const command = await nextCommand();
                const [kind, ...parts] = command.split("-");
                if (kind !== "watch" && kind !== "query") continue;
                const token = parts.join("-");
                if (kind === "watch") this.watch = token;
                this.publish(kind, token);
            }
        });
    }

    publish(kind, token) {
        const current = focused();
        const address = keyboardTerminal(current);
        const record = address && !address.includes("/")
            ? terminals().find(t => t.address === address && t.state === "live")
            : null;
        const focus = {
            pane: current?.pane ?? null,
            terminal: address,
            pid: record?.pid ?? record?.foreground?.pid ?? null,
            toast: layout()?.toast ?? null,
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
