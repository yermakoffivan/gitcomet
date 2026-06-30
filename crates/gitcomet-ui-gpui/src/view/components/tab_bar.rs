use crate::theme::AppTheme;
use gpui::prelude::*;
use gpui::{AnyElement, Div, ElementId, IntoElement, Stateful, div, px};

pub struct TabBar {
    id: ElementId,
    tabs: Vec<AnyElement>,
    end: Vec<AnyElement>,
}

impl TabBar {
    pub fn new(id: impl Into<ElementId>) -> Self {
        Self {
            id: id.into(),
            tabs: Vec::new(),
            end: Vec::new(),
        }
    }

    pub fn tab(mut self, tab: impl IntoElement) -> Self {
        self.tabs.push(tab.into_any_element());
        self
    }

    pub fn end_child(mut self, child: impl IntoElement) -> Self {
        self.end.push(child.into_any_element());
        self
    }

    pub fn render(self, _theme: AppTheme, _ui_scale_percent: u32) -> Stateful<Div> {
        let tabs = div()
            .id((self.id.clone(), "tabs"))
            .flex()
            .items_center()
            .h_full()
            .overflow_x_scroll()
            .scrollbar_width(px(0.0))
            .children(self.tabs);

        div()
            .id(self.id)
            .group("tab_bar")
            .flex()
            .flex_none()
            .items_center()
            .w_full()
            .h_full()
            .child(
                div()
                    .relative()
                    .flex_1()
                    .h_full()
                    .overflow_x_hidden()
                    .child(tabs),
            )
            .when(!self.end.is_empty(), |this| {
                this.child(
                    div()
                        .flex()
                        .items_center()
                        .gap(px(0.0))
                        .h_full()
                        .children(self.end),
                )
            })
    }
}
