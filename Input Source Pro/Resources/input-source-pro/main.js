import { View, div } from "gpui-kit";
import { checking, focused, nextCommand, setShared, terminals } from "herdr";

export default class InputSourceFocus extends View {
    init(_props, cx) {
        if (checking()) return;
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
        const address = current?.shown ?? current?.terminal ?? null;
        const record = address && !address.includes("/")
            ? terminals().find(t => t.address === address && t.state === "live")
            : null;
        const focus = {
            pane: current?.pane ?? null,
            terminal: address,
            pid: record?.pid ?? record?.foreground?.pid ?? null,
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
        if (this.watch) setShared("input-source-pro.watch", null);
    }
}
