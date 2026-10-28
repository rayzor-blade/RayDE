package ui;

import ashui.layout.Element;
import state.BoardStore;

/** HXX composes typed components; each child observes the signals it reads. */
class BoardApp {
    final store = new BoardStore();
    public function new() {}

    public function render():Element {
        return <div class="pocket-app flex flex-col flex-1 min-h-0 bg-background text-text-primary p-6 gap-5">
            ${BoardHeader.view(store)}
            ${BoardStats.view(store)}
            <div class="flex flex-1 min-h-0 gap-4">
                <div class="flex flex-1 min-w-0 gap-3">
                    ${BoardColumn.view(store, "Ideas")}
                    ${BoardColumn.view(store, "Building")}
                    ${BoardColumn.view(store, "Shipped")}
                </div>
                ${TaskInspector.view(store)}
            </div>
            <text class="text-xs text-text-secondary">${store.message.get()}</text>
        </div>;
    }
}
