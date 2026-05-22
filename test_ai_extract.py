import requests
import json
from datetime import datetime

API_KEY = 'ak_2o89sS1gm81S8b90Lp7Oq2PZ9j14L'
BASE_URL = 'https://api.longcat.chat/openai/v1'
MODEL_NAME = 'LongCat-2.0-Preview'

SYSTEM_PROMPT = '''智能提取助手，将文本内容映射到Schema，输出JSON数组。

---
[上下文]
{context_str}

[Schema]
{schema}

[规则]
1. 多事件→多元素
2. 未提及字段不输出，未映射细节→n
3. date: yyyy-MM-dd
4. t格式: HH:mm，跨天用-前缀(如-23:00=昨晚)，范围用~连接(如-23:00~8:00)
5. 模糊时间：早8 午12:30 晚19 宵23
6. 财务意向→consumption，有categories加_category
7. n极简，不重复已映射信息

[例子]
"昨晚十点睡，睡了八个小时" → [{{"id":"sleep","t":"-22:00~6:00","f":{{"duration":8}}}}]
"吃了一碗螺蛳粉，花了10元" → [{{"id":"diet","f":{{"item":"正餐"}},"n":"螺蛳粉"}},{{"id":"consumption","f":{{"_category":"expense","type":"饮食","amount":10}}}}]
"早上吃了玉米鸡蛋油条" → [{{"id":"diet","t":"8:00","f":{{"item":"正餐"}},"n":"玉米鸡蛋油条"}}]

---
[输入]
{text}'''

SCHEMA = '''[
  {{'id': 'sleep', 'name': '睡眠', 'fields': [
    {{'id': 'duration', 'name': '时长 (小时)', 'type': 'number'}},
    {{'id': 'quality', 'name': '睡眠质量', 'type': 'select', 'options': ['极好', '良好', '一般', '较差']}}
  ]}},
  {{'id': 'diet', 'name': '饮食'}},
  {{'id': 'activity', 'name': '活动'}},
  {{'id': 'consumption', 'name': '记账', 'categories': [
    {{'id': 'expense', 'name': '支出', 'fields': [
      {{'id': 'type', 'name': '支出类型', 'type': 'select', 'options': ['饮食', '交通', '购物', '娱乐', '居家', '人情', '医疗', '房租', '数码', '其他']}},
      {{'id': 'amount', 'name': '金额', 'type': 'number'}}
    ]}},
    {{'id': 'income', 'name': '收入', 'fields': [
      {{'id': 'incomeType', 'name': '收入类型', 'type': 'select', 'options': ['工资', '奖金', '红包', '兼职', '理财', '其他']}},
      {{'id': 'amount', 'name': '金额', 'type': 'number'}}
    ]}}
  ]}}
]'''

def get_context_str():
    now = datetime.now()
    weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日']
    return {
        'date': now.strftime('%Y-%m-%d'),
        'time': now.strftime('%H:%M'),
        'weekday': weekdays[now.weekday()],
    }

def call_ai(user_input: str) -> dict:
    context_str = get_context_str()
    
    system_prompt = SYSTEM_PROMPT.format(
        context_str=str(context_str),
        schema=SCHEMA,
        text=user_input
    )
    
    headers = {
        'Content-Type': 'application/json',
        'Authorization': f'Bearer {API_KEY}',
    }
    
    payload = {
        'model': MODEL_NAME,
        'messages': [
            {'role': 'system', 'content': system_prompt},
            {'role': 'user', 'content': user_input},
        ],
        'temperature': 0.7,
        'max_tokens': 1024,
        'response_format': {'type': 'json_object'},
    }
    
    response = requests.post(
        f'{BASE_URL}/chat/completions',
        headers=headers,
        json=payload,
        timeout=60,
    )
    
    data = response.json()
    
    if 'error' in data:
        raise Exception(f"API Error: {data['error']}")
    
    if 'choices' not in data or not data['choices']:
        raise Exception(f"Unexpected response: {json.dumps(data, ensure_ascii=False, indent=2)}")
    
    message = data['choices'][0].get('message', {})
    content = message.get('content')
    
    if content is None:
        raise Exception(f"No content in response: {json.dumps(data, ensure_ascii=False, indent=2)}")
    
    return data

def parse_simplified_time(t: str) -> dict:
    result = {}
    
    if '~' in t:
        parts = t.split('~')
        start_part = parts[0]
        end_part = parts[1]
        
        if start_part:
            if start_part.startswith('-'):
                result['start'] = start_part[1:]
                result['startOffset'] = -1
            else:
                result['start'] = start_part
        
        if end_part:
            if end_part.startswith('-'):
                result['end'] = end_part[1:]
                result['endOffset'] = -1
            else:
                result['end'] = end_part
                result['endOffset'] = 0
    else:
        if t.startswith('-'):
            result['start'] = t[1:]
            result['startOffset'] = -1
        else:
            result['start'] = t
    
    return result

def convert_result(simplified: dict) -> dict:
    result = {}
    
    result['shortcutId'] = simplified.get('id') or simplified.get('shortcutId')
    
    if 't' in simplified:
        result['time'] = parse_simplified_time(simplified['t'])
    elif 'time' in simplified:
        result['time'] = simplified['time']
    else:
        result['time'] = {}
    
    result['fields'] = simplified.get('f') or simplified.get('fields') or {}
    result['notes'] = simplified.get('n') or simplified.get('notes') or ''
    
    if 'date' in simplified:
        result['date'] = simplified['date']
    
    return result

def main():
    print('=' * 60)
    print('AI 提取测试工具')
    print('=' * 60)
    print(f'模型: {MODEL_NAME}')
    print(f'当前时间: {datetime.now().strftime("%Y-%m-%d %H:%M")}')
    print('=' * 60)
    print()
    
    test_inputs = [
        '昨晚十点睡，睡了八个小时',
        '吃了一碗螺蛳粉，花了10元',
        '早上吃了玉米鸡蛋油条',
        '昨晚11点半才睡，睡得极差',
        '今天下午喝了杯美式，花了18元',
        '昨晚一点才睡着，今天早上吃了米粉',
    ]
    
    print('预设测试用例:')
    for i, text in enumerate(test_inputs, 1):
        print(f'  {i}. {text}')
    print('  0. 自定义输入')
    print()
    
    while True:
        try:
            choice = input('请选择测试用例编号 (1-6, 0=自定义, q=退出): ').strip()
            
            if choice.lower() == 'q':
                print('退出测试')
                break
            
            if choice == '0':
                user_input = input('请输入测试文本: ').strip()
                if not user_input:
                    print('输入不能为空')
                    continue
            else:
                idx = int(choice) - 1
                if 0 <= idx < len(test_inputs):
                    user_input = test_inputs[idx]
                else:
                    print('无效选择')
                    continue
            
            print()
            print('-' * 60)
            print(f'输入: {user_input}')
            print('-' * 60)
            
            response = call_ai(user_input)
            content = response['choices'][0]['message']['content']
            
            print('原始输出:')
            print(content)
            print()
            
            try:
                json_result = json.loads(content)
                
                if isinstance(json_result, list):
                    results = json_result
                else:
                    results = [json_result]
                
                converted = [convert_result(r) for r in results]
                
                print('转换后结果:')
                print(json.dumps(converted, ensure_ascii=False, indent=2))
            except json.JSONDecodeError as e:
                print(f'JSON 解析失败: {e}')
            
            print()
            
        except KeyboardInterrupt:
            print('\n退出测试')
            break
        except Exception as e:
            print(f'错误: {e}')
            import traceback
            traceback.print_exc()

if __name__ == '__main__':
    main()
