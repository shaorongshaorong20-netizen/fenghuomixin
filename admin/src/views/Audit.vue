<template>
  <div class="page">
    <el-alert
      type="info"
      :closable="false"
      show-icon
      title="仅记录通信行为日志，不存储消息明文内容"
      class="tip"
    />

    <div class="toolbar">
      <el-input v-model="sender" placeholder="发送方" clearable style="max-width: 240px">
        <template #prefix>
          <el-icon><User /></el-icon>
        </template>
      </el-input>
      <el-input v-model="receiver" placeholder="接收方" clearable style="max-width: 240px">
        <template #prefix>
          <el-icon><User /></el-icon>
        </template>
      </el-input>
      <div class="actions">
        <el-button type="danger" @click="load">查询</el-button>
        <el-button @click="reset">重置</el-button>
      </div>
    </div>

    <el-card class="card">
      <el-table :data="rows" v-loading="loading" style="width: 100%">
        <el-table-column prop="sender" label="发送方" min-width="160" />
        <el-table-column prop="receiver" label="接收方" min-width="160" />
        <el-table-column prop="messageType" label="消息类型" width="120">
          <template #default="{ row }">
            <el-tag :type="row.messageType === '图片' ? 'warning' : 'info'">
              {{ row.messageType }}
            </el-tag>
          </template>
        </el-table-column>
        <el-table-column prop="time" label="时间" min-width="200" />
      </el-table>
    </el-card>
  </div>
</template>

<script setup>
import { onMounted, ref } from 'vue'
import { ElMessage } from 'element-plus'

import { fetchAdminMessages } from '../api'

const loading = ref(false)
const sender = ref('')
const receiver = ref('')
const rows = ref([])

function toMessageType(item) {
  const t = String(item?.type ?? item?.message_type ?? item?.messageType ?? '').toLowerCase()
  if (t.includes('image') || t.includes('pic') || t.includes('图片')) return '图片'
  if (t.includes('text') || t.includes('文字')) return '文字'

  const content = String(item?.content ?? '')
  const lower = content.toLowerCase()
  if (content === '[图片]' || content === '[拍照]') return '图片'
  if (
    lower.endsWith('.png') ||
    lower.endsWith('.jpg') ||
    lower.endsWith('.jpeg') ||
    lower.endsWith('.gif') ||
    lower.endsWith('.webp') ||
    lower.endsWith('.heic')
  ) {
    return '图片'
  }
  return '文字'
}

function normalize(data) {
  const list = data?.messages || data?.data || []
  if (!Array.isArray(list)) return []
  return list.map((m) => {
    const from =
      m?.fromUsername ||
      m?.from_username ||
      m?.sender ||
      m?.senderName ||
      m?.sender_username ||
      m?.fromId ||
      m?.from_id ||
      m?.senderId ||
      m?.sender_id ||
      ''
    const to =
      m?.toUsername ||
      m?.to_username ||
      m?.receiver ||
      m?.receiverName ||
      m?.receiver_username ||
      m?.toId ||
      m?.to_id ||
      m?.receiverId ||
      m?.receiver_id ||
      ''
    const time = m?.time || m?.timestamp || m?.created_at || m?.createdAt || ''
    return {
      sender: String(from || ''),
      receiver: String(to || ''),
      messageType: toMessageType(m),
      time: String(time || ''),
    }
  })
}

async function load() {
  loading.value = true
  try {
    const params = {}
    if (sender.value.trim()) params.sender = sender.value.trim()
    if (receiver.value.trim()) params.receiver = receiver.value.trim()
    const data = await fetchAdminMessages(params)
    rows.value = normalize(data)
  } catch (e) {
    const msg = e?.response?.data?.message || e?.message || '加载失败'
    ElMessage.error(String(msg))
  } finally {
    loading.value = false
  }
}

function reset() {
  sender.value = ''
  receiver.value = ''
  load()
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
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  flex-wrap: wrap;
}

.actions {
  display: flex;
  gap: 10px;
}

.card {
  border-radius: 16px;
}
</style>

