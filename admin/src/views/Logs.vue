<template>
  <div class="page">
    <el-alert
      type="warning"
      :closable="false"
      show-icon
      title="系统日志仅可查看，不可编辑或删除"
      class="tip"
    />

    <div class="toolbar">
      <el-button @click="load">刷新</el-button>
    </div>

    <el-card class="card">
      <el-table :data="rows" v-loading="loading" style="width: 100%">
        <el-table-column prop="operator" label="操作人" min-width="160" />
        <el-table-column prop="action" label="操作类型" min-width="180" />
        <el-table-column prop="target" label="操作对象" min-width="200" />
        <el-table-column prop="time" label="时间" min-width="200" />
      </el-table>
    </el-card>
  </div>
</template>

<script setup>
import { onMounted, ref } from 'vue'
import { ElMessage } from 'element-plus'

import { fetchAdminLogs } from '../api'

const loading = ref(false)
const rows = ref([])

function normalize(data) {
  const list = data?.logs || data?.data || []
  if (!Array.isArray(list)) return []
  return list.map((l) => {
    const operator =
      l?.operator ||
      l?.username ||
      l?.admin ||
      l?.adminUsername ||
      l?.operator_name ||
      l?.operatorName ||
      ''
    const action = l?.action || l?.type || l?.operation || l?.actionType || ''
    const target = l?.target || l?.object || l?.resource || l?.subject || ''
    const time = l?.time || l?.timestamp || l?.created_at || l?.createdAt || ''
    return {
      operator: String(operator || ''),
      action: String(action || ''),
      target: String(target || ''),
      time: String(time || ''),
    }
  })
}

async function load() {
  loading.value = true
  try {
    const data = await fetchAdminLogs()
    rows.value = normalize(data)
  } catch (e) {
    const msg = e?.response?.data?.message || e?.message || '加载失败'
    ElMessage.error(String(msg))
  } finally {
    loading.value = false
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

.tip {
  border: 1px solid #1a1f2e;
  background: #0f131e;
}

.toolbar {
  display: flex;
  justify-content: flex-end;
}

.card {
  border-radius: 16px;
}
</style>

