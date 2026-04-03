const KeyboardHook = {
  mounted() {
    this.handleKeydown = (e) => {
      const tag = e.target.tagName
      if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return
      if (e.target.isContentEditable) return

      // Cmd/Ctrl + Shift + number → switch views
      if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key >= "1" && e.key <= "3") {
        e.preventDefault()
        const views = ["fleet", "agents", "activity"]
        this.pushEvent("switch_view", { view: views[parseInt(e.key) - 1] })
        return
      }

      // Cmd/Ctrl + number → select repo
      if ((e.metaKey || e.ctrlKey) && e.key >= "1" && e.key <= "9") {
        e.preventDefault()
        this.pushEvent("key:select_repo", { index: parseInt(e.key) - 1 })
        return
      }

      // Skip if any modifier is held (except shift)
      if (e.metaKey || e.ctrlKey || e.altKey) return

      // Number keys 1-3: switch center tabs
      const tabs = ["graph", "changes", "review"]
      if (e.key >= "1" && e.key <= "3") {
        e.preventDefault()
        this.pushEvent("switch_tab", { tab: tabs[parseInt(e.key) - 1] })
        return
      }

      // [ and ] — prev/next repo
      if (e.key === "[") {
        e.preventDefault()
        this.pushEvent("key:prev_repo", {})
        return
      }
      if (e.key === "]") {
        e.preventDefault()
        this.pushEvent("key:next_repo", {})
        return
      }

      switch (e.key) {
        case "s":
          e.preventDefault()
          this.pushEvent("key:stage_focused", {})
          break
        case "u":
          e.preventDefault()
          this.pushEvent("key:unstage_focused", {})
          break
        case "c":
          e.preventDefault()
          this.pushEvent("key:focus_commit", {})
          break
        case "p":
          e.preventDefault()
          this.pushEvent("key:push", {})
          break
        case "l":
          e.preventDefault()
          this.pushEvent("key:pull", {})
          break
        case "a":
          e.preventDefault()
          this.pushEvent("key:stage_all", {})
          break
        case "d":
          e.preventDefault()
          this.pushEvent("key:discard_focused", {})
          break
        case "b":
          e.preventDefault()
          this.pushEvent("key:toggle_branch", {})
          break
        // Review navigation
        case "j":
          e.preventDefault()
          this.pushEvent("key:review_next", {})
          break
        case "k":
          e.preventDefault()
          this.pushEvent("key:review_prev", {})
          break
        case "y":
          e.preventDefault()
          this.pushEvent("key:review_mark", {})
          break
        case "n":
          e.preventDefault()
          this.pushEvent("key:review_skip", {})
          break
        case "?":
          e.preventDefault()
          this.pushEvent("key:show_help", {})
          break
      }
    }

    window.addEventListener("keydown", this.handleKeydown)

    this.handleEvent("focus-commit-input", () => {
      const input = document.querySelector(".valkka-commit-input")
      if (input) input.focus()
    })

    this.handleEvent("confirm-push", () => {
      if (confirm("Push to origin?")) {
        this.pushEvent("key:push", { confirmed: true })
      }
    })

    this.handleEvent("confirm-pull", () => {
      if (confirm("Pull from origin (fast-forward only)?")) {
        this.pushEvent("key:pull", { confirmed: true })
      }
    })

    this.handleEvent("confirm-discard", () => {
      const selected = document.querySelector(".valkka-file-row.selected")
      if (!selected) return
      const section = selected.closest(".valkka-changes-section")
      const title = section?.querySelector(".valkka-section-label")?.textContent?.trim()
      if (!title || !title.startsWith("Unstaged")) return
      const file = selected.querySelector(".valkka-file-name")?.textContent?.trim()
      if (file && confirm(`Discard changes to ${file}?`)) {
        this.pushEvent("key:discard_confirmed", { file })
      }
    })
  },

  destroyed() {
    window.removeEventListener("keydown", this.handleKeydown)
  }
}

export default KeyboardHook
