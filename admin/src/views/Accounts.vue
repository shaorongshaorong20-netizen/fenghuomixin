<template>
  <div class="page">
    <div class="toolbar">
      <el-input
        v-model="keyword"
        placeholder="搜索用户名"
        clearable
        style="max-width: 320px"
      >
        <template #prefix>
          <el-icon><Search /></el-icon>
        </template>
      </el-input>
      <div class="actions">
        <el-button type="danger" @click="openCreate">创建账号</el-button>
        <el-button @click="load">刷新</el-button>
      </div>
    </div>

    <el-card class="card">
      <el-table :data="filtered" v-loading="loading" style="width: 100%">
        <el-table-column prop="id" label="ID" width="90" />
        <el-table-column prop="username" label="用户名" min-width="180" />
        <el-table-column prop="created_by_admin_username" label="创建者" min-width="160">
          <template #default="{ row }">
            {{ row.created_by_admin_username || '-' }}
          </template>
        </el-table-column>
        <el-table-column label="状态" width="120">
          <template #default="{ row }">
            <el-tag :type="row.status === 1 ? 'success' : 'info'">
              {{ row.status === 1 ? '启用' : '禁用' }}
            </el-tag>
          </template>
        </el-table-column>
        <el-table-column prop="created_at" label="创建时间" min-width="200" />
        <el-table-column prop="last_login" label="最后登录" min-width="200" />
        <el-table-column label="操作" width="230" fixed="right">
          <template #default="{ row }">
            <el-button size="small" @click="toggleStatus(row)">
              {{ row.status === 1 ? '禁用' : '启用' }}
            </el-button>
            <el-button size="small" type="danger" plain @click="remove(row)">
              删除
            </el-button>
          </template>
        </el-table-column>
      </el-table>
    </el-card>

    <el-dialog v-model="createOpen" title="创建账号" width="420px">
      <el-form :model="createForm" label-position="top">
        <el-form-item label="用户名">
          <el-input v-model="createForm.username" placeholder="请输入用户名" />
        </el-form-item>
        <el-form-item label="密码">
          <el-input v-model="createForm.password" placeholder="请输入密码" show-password />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="createOpen = false">取消</el-button>
        <el-button
          type="danger"
          :loading="creating"
          :disabled="!createForm.username || !createForm.password"
          @click="create"
        >
          创建
        </el-button>
      </template>
    </el-dialog>
  </div>
</template>

<script setup>
import { computed, onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'

import { createAccount, deleteAccount, fetchAccounts, updateAccountStatus } from '../api'

const loading = ref(false)
const accounts = ref([])
const keyword = ref('')

const createOpen = ref(false)
const creating = ref(false)
const createForm = reactive({ username: '', password: '' })

function normalizeAccounts(data) {
  const list = data?.accounts || data?.data || []
  if (!Array.isArray(list)) return []
  return list.map((a) => ({
    id: a.id ?? a.userId ?? a.accountId,
    username: a.username ?? a.name ?? '',
    created_by_admin_username:
      a.created_by_admin_username ?? a.createdByAdminUsername ?? a.created_by_admin ?? '',
    status:
      String(a.status ?? '').toLowerCase() === 'active'
        ? 1
        : String(a.status ?? '').toLowerCase() === 'disabled'
          ? 0
          : Number(a.status ?? 1) === 1
            ? 1
            : 0,
    created_at: a.created_at ?? a.createdAt ?? '',
    last_login: a.last_login ?? a.lastLogin ?? '',
  }))
}

const filtered = computed(() => {
  const kw = keyword.value.trim().toLowerCase()
  if (!kw) return accounts.value
  return accounts.value.filter((a) => String(a.username).toLowerCase().includes(kw))
})

async function load() {
  loading.value = true
  try {
    const data = await fetchAccounts()
    accounts.value = normalizeAccounts(data)
  } catch (e) {
    const msg = e?.response?.data?.message || e?.message || '加载失败'
    ElMessage.error(String(msg))
  } finally {
    loading.value = false
  }
}

function openCreate() {
  createForm.username = ''
  createForm.password = ''
  createOpen.value = true
}

async function create() {
  if (creating.value) return
  creating.value = true
  try {
    await createAccount({
      username: createForm.username.trim(),
      password: createForm.password,
    })
    ElMessage.success('创建成功')
    createOpen.value = false
    await load()
  } catch (e) {
    const msg = e?.response?.data?.message || e?.message || '创建失败'
    ElMessage.error(String(msg))
  } finally {
    creating.value = false
  }
}

async function toggleStatus(row) {
  const next = row.status === 1 ? 0 : 1
  try {
    await updateAccountStatus({ id: row.id, status: next })
    ElMessage.success('已更新')
    await load()
  } catch (e) {
    const msg = e?.response?.data?.message || e?.message || '更新失败'
    ElMessage.error(String(msg))
  }
}

async function remove(row) {
  try {
    await ElMessageBox.confirm(`确认删除账号「${row.username}」？`, '删除账号', {
      confirmButtonText: '删除',
      cancelButtonText: '取消',
      type: 'warning',
    })
  } catch (_) {
    return
  }

  try {
    await deleteAccount(row.id)
    ElMessage.success('已删除')
    await load()
  } catch (e) {
    const msg = e?.response?.data?.message || e?.message || '删除失败'
    ElMessage.error(String(msg))
  }
}

onMounted(load)
</script>

<style scoped>
.page {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}

.actions {
  display: flex;
  gap: 10px;
}

.card {
  border-radius: 16px;
}
</style>
