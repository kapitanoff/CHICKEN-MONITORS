// ─── Константы ───────────────────────────────────────────────
const STATUS_LABELS = {
    green:   'Норма',
    yellow:  'Предупреждение',
    red:     'Опасно',
    unknown: 'Нет данных'
};

// ─── Состояние ───────────────────────────────────────────────
let chartInstance    = null;   // текущий график Chart.js
let selectedChicken  = null;   // ID курицы открытой в модалке
let selectedHours    = 1;      // выбранный период графика

let currentPage      = 1;      // текущая страница
let totalPages       = 1;      // всего страниц
const perPage        = 20;     // куриц на странице
let renderedPage     = 0;      // последняя отрисованная страница

let viewMode         = 'all';  // 'all' | 'groups'
let groupsCache      = [];     // кэш списка групп
let collapsedGroups  = new Set(); // ID свёрнутых секций

// ─── Загрузка групп ─────────────────────────────────────────

async function loadGroups() {
    try {
        const res = await fetch('/api/groups');
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        groupsCache = await res.json();
    } catch (err) {
        console.error('Ошибка загрузки групп:', err);
    }
    return groupsCache;
}

// ─── Загрузка и отрисовка сетки ──────────────────────────────

async function loadChickens() {
    if (viewMode === 'groups') {
        await loadChickensGrouped();
        return;
    }

    let data;
    try {
        const res = await fetch(`/api/chickens?page=${currentPage}&per_page=${perPage}`);
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        data = await res.json();
    } catch (err) {
        console.error('Ошибка загрузки куриц:', err);
        return;
    }

    const grid     = document.getElementById('grid');
    const emptyMsg = document.getElementById('empty-msg');

    emptyMsg.style.display = data.total === 0 ? 'block' : 'none';

    // При смене страницы очищаем сетку полностью
    if (currentPage !== renderedPage) {
        grid.innerHTML = '';
        renderedPage = currentPage;
    }

    data.items.forEach(c => {
        let cell = document.getElementById(`cell-${c.chicken_id}`);

        if (!cell) {
            cell = document.createElement('div');
            cell.id = `cell-${c.chicken_id}`;

            cell.innerHTML = `
                <div class="cell-id">Курица #${escapeHtml(String(c.chicken_id))}</div>
                <div class="cell-temp">—<span class="unit"> °C</span></div>
                <div class="cell-voltage">— V</div>
                <div class="cell-badge">—</div>
            `;

            cell.addEventListener('click', () => openModal(c.chicken_id));
            grid.appendChild(cell);
        }

        updateCell(cell, c);
    });

    document.getElementById('pagination').classList.toggle('hidden', false);
    renderPagination(data.total);
}

// ─── Загрузка по группам ────────────────────────────────────

async function loadChickensGrouped() {
    const groups = await loadGroups();

    let allData;
    try {
        const res = await fetch('/api/chickens?all=true');
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        allData = await res.json();
    } catch (err) {
        console.error('Ошибка загрузки куриц:', err);
        return;
    }

    const grid     = document.getElementById('grid');
    const emptyMsg = document.getElementById('empty-msg');

    emptyMsg.style.display = allData.total === 0 ? 'block' : 'none';
    document.getElementById('pagination').classList.add('hidden');

    grid.innerHTML = '';
    grid.classList.add('grouped');

    // Группируем куриц
    const grouped = {};
    const ungrouped = [];

    allData.items.forEach(c => {
        if (c.group_id != null) {
            if (!grouped[c.group_id]) grouped[c.group_id] = [];
            grouped[c.group_id].push(c);
        } else {
            ungrouped.push(c);
        }
    });

    // Отрисовка секций для каждой группы
    groups.forEach(g => {
        const chickens = grouped[g.id] || [];
        const section = createGroupSection(g.name, chickens, `group-${g.id}`);
        grid.appendChild(section);
    });

    // Секция "Без загона"
    if (ungrouped.length > 0) {
        const section = createGroupSection('Без загона', ungrouped, 'ungrouped');
        section.classList.add('ungrouped');
        grid.appendChild(section);
    }
}

function createGroupSection(name, chickens, groupId) {
    const section = document.createElement('div');
    section.className = 'group-section';
    section.dataset.groupId = groupId;

    // Восстанавливаем свёрнутое состояние
    if (collapsedGroups.has(groupId)) {
        section.classList.add('collapsed');
    }

    const header = document.createElement('div');
    header.className = 'group-section-header';
    header.innerHTML = `
        <span class="toggle-arrow">\u25BC</span>
        <span class="group-name">${escapeHtml(name)}</span>
        <span class="group-count">${chickens.length} шт</span>
    `;
    header.addEventListener('click', () => {
        section.classList.toggle('collapsed');
        if (section.classList.contains('collapsed')) {
            collapsedGroups.add(groupId);
        } else {
            collapsedGroups.delete(groupId);
        }
    });
    section.appendChild(header);

    const sectionGrid = document.createElement('div');
    sectionGrid.className = 'group-grid';
    section.appendChild(sectionGrid);

    chickens.forEach(c => {
        const cell = document.createElement('div');
        cell.id = `cell-${c.chicken_id}`;

        cell.innerHTML = `
            <div class="cell-id">Курица #${escapeHtml(String(c.chicken_id))}</div>
            <div class="cell-temp">—<span class="unit"> °C</span></div>
            <div class="cell-voltage">— V</div>
            <div class="cell-badge">—</div>
        `;

        cell.addEventListener('click', () => openModal(c.chicken_id));
        updateCell(cell, c);
        sectionGrid.appendChild(cell);
    });

    return section;
}

// Обновляет данные внутри ячейки
function updateCell(cell, data) {
    const status = data.status || 'unknown';

    cell.className = `cell ${status}`;

    cell.querySelector('.cell-temp').innerHTML =
        data.temperature != null
            ? `${data.temperature.toFixed(1)}<span class="unit"> °C</span>`
            : `—<span class="unit"> °C</span>`;

    cell.querySelector('.cell-voltage').textContent =
        data.voltage != null ? `${data.voltage.toFixed(2)} V` : '— V';

    cell.querySelector('.cell-badge').textContent =
        STATUS_LABELS[status] || '—';
}

// ─── Пагинация ───────────────────────────────────────────────

function renderPagination(total) {
    totalPages = Math.ceil(total / perPage) || 1;

    const paginationEl = document.getElementById('pagination');
    const pageInfoEl   = document.getElementById('page-info');
    const btnPrev      = document.getElementById('btn-prev');
    const btnNext      = document.getElementById('btn-next');

    paginationEl.classList.toggle('hidden', totalPages <= 1);

    pageInfoEl.textContent = `Страница ${currentPage} из ${totalPages}`;

    btnPrev.disabled = currentPage <= 1;
    btnNext.disabled = currentPage >= totalPages;
}

document.getElementById('btn-prev').addEventListener('click', async () => {
    if (currentPage > 1) {
        currentPage--;
        await loadChickens();
    }
});

document.getElementById('btn-next').addEventListener('click', async () => {
    if (currentPage < totalPages) {
        currentPage++;
        await loadChickens();
    }
});

// ─── Переключение вида ──────────────────────────────────────

document.getElementById('btn-view-all').addEventListener('click', () => {
    if (viewMode === 'all') return;
    viewMode = 'all';
    document.getElementById('btn-view-all').classList.add('active');
    document.getElementById('btn-view-groups').classList.remove('active');
    currentPage = 1;
    renderedPage = 0;
    const grid = document.getElementById('grid');
    grid.innerHTML = '';
    grid.classList.remove('grouped');
    loadChickens();
});

document.getElementById('btn-view-groups').addEventListener('click', () => {
    if (viewMode === 'groups') return;
    viewMode = 'groups';
    document.getElementById('btn-view-groups').classList.add('active');
    document.getElementById('btn-view-all').classList.remove('active');
    document.getElementById('grid').innerHTML = '';
    loadChickens();
});

// ─── Модальное окно с графиком ───────────────────────────────

async function openModal(chickenId) {
    selectedChicken = chickenId;
    selectedHours   = 1;

    document.getElementById('modal-title').textContent = `Курица #${String(chickenId)}`;
    document.getElementById('modal').classList.remove('hidden');

    // Сбрасываем активную кнопку времени на "1 час"
    document.querySelectorAll('.time-btn').forEach(btn => {
        btn.classList.toggle('active', parseInt(btn.dataset.hours) === 1);
    });

    // Заполняем dropdown групп
    await loadGroups();
    const select = document.getElementById('modal-group-select');
    select.innerHTML = '<option value="">Без загона</option>';
    groupsCache.forEach(g => {
        const opt = document.createElement('option');
        opt.value = g.id;
        opt.textContent = g.name;
        select.appendChild(opt);
    });

    // Определяем текущую группу курицы
    try {
        const res = await fetch('/api/chickens?all=true');
        if (res.ok) {
            const data = await res.json();
            const chicken = data.items.find(c => c.chicken_id === chickenId);
            if (chicken) {
                select.value = chicken.group_id != null ? chicken.group_id : '';
            }
        }
    } catch (_) {}

    await loadChart(chickenId, selectedHours);
}

// Обработчик смены группы в модалке
document.getElementById('modal-group-select').addEventListener('change', async (e) => {
    if (!selectedChicken) return;
    const groupId = e.target.value === '' ? null : parseInt(e.target.value);
    try {
        await fetch(`/api/chickens/${encodeURIComponent(selectedChicken)}/group`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ group_id: groupId })
        });
        // Обновить сетку
        await loadChickens();
    } catch (err) {
        console.error('Ошибка назначения группы:', err);
    }
});

// Загружает историю и строит график
async function loadChart(chickenId, hours) {
    let history;
    try {
        const res = await fetch(`/api/chickens/${encodeURIComponent(chickenId)}/history?hours=${hours}`);
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        history = await res.json();
    } catch (err) {
        console.error('Ошибка загрузки истории:', err);
        document.getElementById('modal-info').textContent = 'Ошибка загрузки данных';
        return;
    }

    // Подписи оси X — время в формате ЧЧ:ММ
    const labels = history.map(r => {
        const d = new Date(r.timestamp);
        return d.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' });
    });

    const temps = history.map(r => r.temperature);

    // Удаляем старый график перед созданием нового
    if (chartInstance) chartInstance.destroy();

    // Обновляем информационную строку под заголовком
    const infoEl = document.getElementById('modal-info');
    if (history.length === 0) {
        infoEl.textContent = 'Нет данных за выбранный период';
    } else {
        const min = Math.min(...temps).toFixed(1);
        const max = Math.max(...temps).toFixed(1);
        const avg = (temps.reduce((a, b) => a + b, 0) / temps.length).toFixed(1);
        infoEl.textContent = `Точек: ${history.length}  •  Мин: ${min}°C  •  Макс: ${max}°C  •  Среднее: ${avg}°C`;
    }

    const ctx = document.getElementById('tempChart').getContext('2d');

    chartInstance = new Chart(ctx, {
        type: 'line',
        data: {
            labels,
            datasets: [{
                label: 'Температура (°C)',
                data: temps,
                borderColor: '#e94560',
                backgroundColor: 'rgba(233, 69, 96, 0.08)',
                fill: true,
                tension: 0.4,
                pointRadius: history.length > 100 ? 0 : 3,
                pointHoverRadius: 5
            }]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            plugins: {
                legend: { labels: { color: '#aaa', font: { size: 12 } } }
            },
            scales: {
                x: {
                    ticks: { color: '#666', maxTicksLimit: 10 },
                    grid:  { color: '#1e1e3a' }
                },
                y: {
                    ticks: { color: '#666' },
                    grid:  { color: '#1e1e3a' }
                }
            }
        }
    });
}

// ─── Кнопки выбора периода ───────────────────────────────────

document.querySelectorAll('.time-btn').forEach(btn => {
    btn.addEventListener('click', async () => {
        selectedHours = parseInt(btn.dataset.hours);

        document.querySelectorAll('.time-btn').forEach(b => b.classList.remove('active'));
        btn.classList.add('active');

        if (selectedChicken) await loadChart(selectedChicken, selectedHours);
    });
});

// ─── Закрытие модалки ────────────────────────────────────────

function closeModal() {
    document.getElementById('modal').classList.add('hidden');
    if (chartInstance) {
        chartInstance.destroy();
        chartInstance = null;
    }
}

document.getElementById('modal-close').addEventListener('click', closeModal);

// Клик на тёмный фон закрывает модалку
document.getElementById('modal').addEventListener('click', e => {
    if (e.target === document.getElementById('modal')) closeModal();
});

// ─── Управление загонами — модалка ───────────────────────────

function openGroupsModal() {
    document.getElementById('groups-modal').classList.remove('hidden');
    renderGroupsList();
}

function closeGroupsModal() {
    document.getElementById('groups-modal').classList.add('hidden');
}

document.getElementById('btn-manage-groups').addEventListener('click', openGroupsModal);
document.getElementById('groups-modal-close').addEventListener('click', closeGroupsModal);
document.getElementById('groups-modal').addEventListener('click', e => {
    if (e.target === document.getElementById('groups-modal')) closeGroupsModal();
});

async function renderGroupsList() {
    await loadGroups();
    const list = document.getElementById('groups-list');

    if (groupsCache.length === 0) {
        list.innerHTML = '<div class="groups-empty">Нет загонов. Создайте первый!</div>';
        return;
    }

    list.innerHTML = '';
    groupsCache.forEach(g => {
        const item = document.createElement('div');
        item.className = 'group-item';
        item.innerHTML = `
            <span class="group-item-name">${escapeHtml(g.name)}</span>
            <div class="group-item-actions">
                <button class="btn-rename" data-id="${g.id}">Переименовать</button>
                <button class="btn-delete" data-id="${g.id}">Удалить</button>
            </div>
        `;

        item.querySelector('.btn-rename').addEventListener('click', async () => {
            const newName = prompt('Новое название загона:', g.name);
            if (newName && newName.trim()) {
                try {
                    await fetch(`/api/groups/${g.id}`, {
                        method: 'PUT',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ name: newName.trim() })
                    });
                    await renderGroupsList();
                    await loadChickens();
                } catch (err) {
                    console.error('Ошибка переименования:', err);
                }
            }
        });

        item.querySelector('.btn-delete').addEventListener('click', async () => {
            if (!confirm(`Удалить загон "${g.name}"? Курицы станут "без загона".`)) return;
            try {
                await fetch(`/api/groups/${g.id}`, { method: 'DELETE' });
                await renderGroupsList();
                await loadChickens();
            } catch (err) {
                console.error('Ошибка удаления:', err);
            }
        });

        list.appendChild(item);
    });
}

// Создание группы
document.getElementById('btn-create-group').addEventListener('click', async () => {
    const input = document.getElementById('new-group-name');
    const name = input.value.trim();
    if (!name) return;

    try {
        const res = await fetch('/api/groups', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ name })
        });
        if (res.ok) {
            input.value = '';
            await renderGroupsList();
            await loadChickens();
        }
    } catch (err) {
        console.error('Ошибка создания группы:', err);
    }
});

// Enter в поле ввода создаёт группу
document.getElementById('new-group-name').addEventListener('keydown', e => {
    if (e.key === 'Enter') document.getElementById('btn-create-group').click();
});

// ─── Утилиты ─────────────────────────────────────────────────

function escapeHtml(str) {
    const div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
}

// ─── Клавиша Escape закрывает любую модалку ─────────────────

document.addEventListener('keydown', e => {
    if (e.key === 'Escape') {
        closeModal();
        closeGroupsModal();
    }
});

// ─── Запуск ──────────────────────────────────────────────────

loadChickens();
setInterval(loadChickens, 3000);
