import SwiftData
import SwiftUI

struct CatalogView: View {
    enum Mode: String, CaseIterable { case categories = "Категории", tags = "Теги" }

    @Environment(AppState.self) private var app
    @Environment(SyncStore.self) private var store
    @State private var mode: Mode = .categories

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .categories: CategoriesList()
                case .tags: TagsList()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Раздел", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding()
                .background(.bar)
            }
            .navigationTitle("Справочники")
            .navigationBarTitleDisplayMode(.inline)
            .offlineIndicator()
            .refreshable { await store.sync(month: nil) }
        }
    }
}

private struct OnlineOnlyFooter: View {
    @Environment(AppState.self) private var app
    var body: some View {
        if !app.isOnline { Text("Изменения доступны только при подключении к сети.") }
    }
}

// MARK: - Categories

private struct CategoriesList: View {
    @Environment(AppState.self) private var app
    @Environment(SyncStore.self) private var store
    @Query(sort: \CachedCategory.position) private var categories: [CachedCategory]

    @State private var editing: CachedCategory?
    @State private var isCreating = false
    @State private var deleting: CachedCategory?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                ForEach(categories) { category in
                    Button { editing = category } label: {
                        HStack(spacing: 12) {
                            CategoryBadge(icon: category.icon, color: category.color)
                            Text(category.name).foregroundStyle(.primary)
                            Spacer()
                            Text("\(category.transactionCount)").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .disabled(!app.isOnline)
                    .swipeActions {
                        if app.isOnline {
                            Button("Удалить", systemImage: "trash", role: .destructive) { deleting = category }
                        }
                    }
                }
            } footer: {
                OnlineOnlyFooter()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isCreating = true } label: { Image(systemName: "plus") }.disabled(!app.isOnline)
            }
        }
        .sheet(isPresented: $isCreating) { CategoryFormView(category: nil) }
        .sheet(item: $editing) { CategoryFormView(category: $0) }
        .sheet(item: $deleting) { target in CategoryDeleteView(category: target, others: categories.filter { $0.id != target.id }) }
        .errorAlert($error)
    }
}

private struct CategoryFormView: View {
    @Environment(SyncStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let category: CachedCategory?

    @State private var name = ""
    @State private var icon = CategoryIcon.all[0].lucide
    @State private var customColor = false
    @State private var color = Color.blue
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        CategoryBadge(icon: icon, color: category?.color ?? (customColor ? color.hexString : "#9CA3AF"), size: 44)
                        TextField("Название", text: $name)
                    }
                }

                Section("Иконка") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(CategoryIcon.all, id: \.lucide) { option in
                            Image(systemName: option.symbol)
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .background(icon == option.lucide ? Color.accentColor.opacity(0.2) : .clear, in: Circle())
                                .foregroundStyle(icon == option.lucide ? Color.accentColor : .primary)
                                .onTapGesture { icon = option.lucide }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    if category == nil {
                        Toggle("Выбрать цвет", isOn: $customColor)
                        if customColor { ColorPicker("Цвет", selection: $color, supportsOpacity: false) }
                    }
                } footer: {
                    Text(category == nil ? "Без своего цвета сервер подберёт его сам. Позже цвет изменить нельзя."
                                         : "Цвет категории изменить нельзя.")
                }
            }
            .navigationTitle(category == nil ? "Новая категория" : "Категория")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving { ProgressView() } else {
                        Button("Сохранить") { Task { await save() } }.disabled(trimmedName.isEmpty || trimmedName.count > 50)
                    }
                }
            }
            .onAppear {
                if let category {
                    name = category.name
                    icon = category.icon
                }
            }
            .errorAlert($error)
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            if let category {
                try await store.updateCategory(id: category.id, UpdateCategoryBody(
                    name: trimmedName == category.name ? nil : trimmedName,
                    icon: icon == category.icon ? nil : icon))
            } else {
                try await store.createCategory(CreateCategoryBody(name: trimmedName, icon: icon,
                                                                  color: customColor ? color.hexString : nil))
            }
            dismiss()
        } catch let apiError as APIError where apiError.status == 409 {
            error = "Категория с таким названием уже есть"
        } catch {
            self.error = APIError.from(error).localizedDescription
        }
    }
}

private struct CategoryDeleteView: View {
    @Environment(SyncStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let category: CachedCategory
    let others: [CachedCategory]

    @State private var reassignTo: String?
    @State private var isDeleting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        CategoryBadge(icon: category.icon, color: category.color)
                        Text(category.name).font(.headline)
                    }
                }
                if category.transactionCount > 0 {
                    Section {
                        Picker("Перенести в", selection: $reassignTo) {
                            Text("Выберите").tag(String?.none)
                            ForEach(others) { Text($0.name).tag(Optional($0.id)) }
                        }
                    } footer: {
                        Text("В категории \(category.transactionCount) опер. Их нужно перенести в другую категорию.")
                    }
                } else {
                    Section { Text("В категории нет операций.").foregroundStyle(.secondary) }
                }
                Section {
                    Button(role: .destructive) { Task { await delete() } } label: {
                        if isDeleting { ProgressView() } else { Text("Удалить категорию") }
                    }
                    .disabled(category.transactionCount > 0 && reassignTo == nil)
                }
            }
            .navigationTitle("Удаление")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
            .errorAlert($error)
        }
        .presentationDetents([.medium])
    }

    private func delete() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await store.deleteCategory(id: category.id, reassignTo: reassignTo)
            dismiss()
        } catch let apiError as APIError where apiError.status == 409 {
            error = "В категории есть операции — выберите, куда их перенести"
            try? await store.refreshCategories()
        } catch {
            self.error = APIError.from(error).localizedDescription
        }
    }
}

// MARK: - Tags

private struct TagsList: View {
    @Environment(AppState.self) private var app
    @Environment(SyncStore.self) private var store
    @Query(sort: \CachedTag.name) private var tags: [CachedTag]

    @State private var editingTag: CachedTag?
    @State private var isEditing = false
    @State private var name = ""
    @State private var deleting: CachedTag?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if tags.isEmpty {
                    Text("Тегов пока нет").foregroundStyle(.secondary)
                }
                ForEach(tags) { tag in
                    Button {
                        editingTag = tag
                        name = tag.name
                        isEditing = true
                    } label: {
                        HStack {
                            Text("#\(tag.name)").foregroundStyle(.primary)
                            Spacer()
                            Text("\(tag.transactionCount)").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .disabled(!app.isOnline)
                    .swipeActions {
                        if app.isOnline {
                            Button("Удалить", systemImage: "trash", role: .destructive) { deleting = tag }
                        }
                    }
                }
            } footer: {
                OnlineOnlyFooter()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingTag = nil
                    name = ""
                    isEditing = true
                } label: { Image(systemName: "plus") }
                .disabled(!app.isOnline)
            }
        }
        .alert(editingTag == nil ? "Новый тег" : "Переименовать тег", isPresented: $isEditing) {
            TextField("Название", text: $name)
            Button("Отмена", role: .cancel) {}
            Button("Сохранить") { Task { await save() } }
        }
        .confirmationDialog("Удалить тег?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { tag in
            Button("Удалить #\(tag.name)", role: .destructive) { Task { await delete(tag) } }
        } message: { tag in
            Text("Тег снимется с \(tag.transactionCount) опер. Сами операции останутся.")
        }
        .errorAlert($error)
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 50 else {
            error = "Название — от 1 до 50 символов"
            return
        }
        do {
            if let editingTag {
                try await store.renameTag(id: editingTag.id, name: trimmed)
            } else {
                try await store.createTag(name: trimmed)
            }
        } catch let apiError as APIError where apiError.status == 409 {
            error = "Тег с таким названием уже есть"
        } catch {
            self.error = APIError.from(error).localizedDescription
        }
    }

    private func delete(_ tag: CachedTag) async {
        do {
            try await store.deleteTag(id: tag.id)
        } catch {
            self.error = APIError.from(error).localizedDescription
        }
    }
}
