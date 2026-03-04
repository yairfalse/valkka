const KeyboardHook = {
  mounted() {
    this.handleKeydown = (e) => {
      const tag = e.target.tagName
      if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return
      if (e.target.isContentEditable) return

      // Cmd/Ctrl + number → select repo
      if ((e.metaKey || e.ctrlKey) && e.key >= "1" && e.key <= "9") {
        e.preventDefault()
        this.pushEvent("key:select_repo", { index: parseInt(e.key) - 1 })
        return
      }

      // Skip if any modifier is held (except shift)
      if (e.metaKey || e.ctrlKey || e.altKey) return

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
      }
    }

    window.addEventListener("keydown", this.handleKeydown)

    this.handleEvent("focus-commit-input", () => {
      const input = document.querySelector(".kanni-commit-input")
      if (input) input.focus()
    })
  },

  destroyed() {
    window.removeEventListener("keydown", this.handleKeydown)
  }
}

export default KeyboardHook
